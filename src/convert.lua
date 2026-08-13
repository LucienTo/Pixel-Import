-- Image loading and pixel-art conversion.
--
-- Two independent reductions, always in this order: resolution first, color
-- second. Downscaling averages neighboring pixels, which invents colors that
-- were never in the source; quantizing afterwards collapses them back onto a
-- small deliberate palette. Quantizing first would spend palette entries on
-- detail that is about to be thrown away.

local convert = {}

local floor = math.floor
local pc    = app.pixelColor
local rgba  = pc.rgba
local rgbaR, rgbaG, rgbaB, rgbaA = pc.rgbaR, pc.rgbaG, pc.rgbaB, pc.rgbaA

-- Sampling budget for one conversion pass. The dialog reconverts on every
-- slider tick, so cost has to scale with the output size, not the input: a
-- 6000px photo and a 600px sprite both have to stay interactive.
local SAMPLE_BUDGET = 300000

-- Source images are capped once, on import. Detail finer than this cannot
-- survive the reduction to sprite scale anyway, and without the cap every
-- later preview pass would keep paying to sample it.
local MAX_SOURCE = 1024

-- Ceiling on the converted image. Two reasons: nothing above this is pixel art
-- in any useful sense, and without it a large photo asks for millions of output
-- pixels on every slider tick. The dialog reports the real output size, so the
-- clamp is visible rather than silent.
local MAX_OUTPUT = 256

local FLAT_FORMATS = {
  png = true, jpg = true, jpeg = true, bmp = true, tga = true,
  webp = true, pcx = true,
}

----------------------------------------------------------------------
-- Color mode normalization
--
-- Everything downstream assumes straight RGBA, so anything else is converted
-- on the way in rather than special-cased in five different places.

local function fromIndexed(img, palette, transparentIndex)
  local out = Image(img.width, img.height, ColorMode.RGB)
  local n = palette and #palette or 0
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local i = img:getPixel(x, y)
      if i ~= transparentIndex and i < n then
        local c = palette:getColor(i)
        out:putPixel(x, y, rgba(c.red, c.green, c.blue, c.alpha))
      end
    end
  end
  return out
end

local function fromGray(img)
  local out = Image(img.width, img.height, ColorMode.RGB)
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local p = img:getPixel(x, y)
      local v, a = pc.grayaV(p), pc.grayaA(p)
      if a > 0 then out:putPixel(x, y, rgba(v, v, v, a)) end
    end
  end
  return out
end

----------------------------------------------------------------------
-- Resampling

-- The resampling filters offered in the dialog, in menu order. Nearest first
-- because it is the default: it is the only one that cannot invent a color,
-- which is what pixel art usually wants. Area average is the better answer for
-- a photograph, and is one place down the list rather than gone.
convert.methods = {
  { id = "nearest",  label = "Nearest neighbor" },
  { id = "area",     label = "Area average" },
  { id = "bilinear", label = "Bilinear" },
  { id = "bicubic",  label = "Bicubic" },
}

function convert.methodLabels()
  local out = {}
  for i, m in ipairs(convert.methods) do out[i] = m.label end
  return out
end

function convert.methodByLabel(label)
  for _, m in ipairs(convert.methods) do
    if m.label == label then return m.id end
  end
  return convert.methods[1].id
end

local function clamp8(v)
  v = floor(v + 0.5)
  if v < 0 then return 0 end
  if v > 255 then return 255 end
  return v
end

local function fetch(src, x, y)
  if x < 0 then x = 0 elseif x >= src.width then x = src.width - 1 end
  if y < 0 then y = 0 elseif y >= src.height then y = src.height - 1 end
  return src:getPixel(x, y)
end

local function bilinearWeights(t, w)
  w[1] = 1 - t
  w[2] = t
end

-- Catmull-Rom. Sharper than bilinear, at the cost of slight overshoot at hard
-- edges, which is why the result is clamped back into range.
local function bicubicWeights(t, w)
  local t2 = t * t
  local t3 = t2 * t
  w[1] = -0.5 * t3 +       t2 - 0.5 * t
  w[2] =  1.5 * t3 - 2.5 * t2 + 1
  w[3] = -1.5 * t3 + 2.0 * t2 + 0.5 * t
  w[4] =  0.5 * t3 - 0.5 * t2
end

-- Nearest neighbor: one source pixel, untouched. The only filter that cannot
-- invent a color, which is what makes it the right answer for a source that
-- is already pixel art.
local function resampleNearest(src, out, ow, oh, sx, sy)
  local sw, sh = src.width, src.height
  for oy = 0, oh - 1 do
    local py = math.min(sh - 1, floor((oy + 0.5) * sy))
    for ox = 0, ow - 1 do
      out:putPixel(ox, oy, src:getPixel(math.min(sw - 1, floor((ox + 0.5) * sx)), py))
    end
  end
end

-- Shared body for the interpolating filters. Both weight a small neighborhood
-- around the sample point; only the weights and their span differ.
local function resampleKernel(src, out, ow, oh, sx, sy, taps, weights)
  local wx, wy = {}, {}
  local offset = (taps == 2) and 1 or 2

  for oy = 0, oh - 1 do
    local fy = (oy + 0.5) * sy - 0.5
    local y0 = floor(fy)
    weights(fy - y0, wy)

    for ox = 0, ow - 1 do
      local fx = (ox + 0.5) * sx - 0.5
      local x0 = floor(fx)
      weights(fx - x0, wx)

      -- Premultiplied, for the same reason the area filter is: an unweighted
      -- transparent neighbor would drag the edge toward its unused channels.
      local acc, g, b, a = 0, 0, 0, 0
      for j = 1, taps do
        local py = y0 + j - offset
        local jw = wy[j]
        if jw ~= 0 then
          for i = 1, taps do
            local w = wx[i] * jw
            if w ~= 0 then
              local p  = fetch(src, x0 + i - offset, py)
              local pa = rgbaA(p) * w
              acc = acc + rgbaR(p) * pa
              g   = g + rgbaG(p) * pa
              b   = b + rgbaB(p) * pa
              a   = a + pa
            end
          end
        end
      end

      if a > 0.001 then
        out:putPixel(ox, oy, rgba(clamp8(acc / a), clamp8(g / a), clamp8(b / a), clamp8(a)))
      end
    end
  end
end

-- Area average, and the entry point for every other filter.
--
-- For the area filter the number of samples per output pixel is capped, so
-- cost is bounded by the output size; at the reductions this tool is for, a
-- bounded sample is indistinguishable from a full box average.
function convert.resample(src, ow, oh, budget, method)
  ow = math.max(1, floor(ow))
  oh = math.max(1, floor(oh))

  local out    = Image(ow, oh, ColorMode.RGB)
  local sw, sh = src.width, src.height
  local sx, sy = sw / ow, sh / oh

  method = method or "area"
  if method == "nearest" then
    resampleNearest(src, out, ow, oh, sx, sy)
    return out
  elseif method == "bilinear" then
    resampleKernel(src, out, ow, oh, sx, sy, 2, bilinearWeights)
    return out
  elseif method == "bicubic" then
    resampleKernel(src, out, ow, oh, sx, sy, 4, bicubicWeights)
    return out
  end

  local per = math.max(1, floor((budget or SAMPLE_BUDGET) / (ow * oh)))
  local n   = math.max(1, floor(math.sqrt(per)))
  local nx  = math.min(n, math.max(1, floor(sx)))
  local ny  = math.min(n, math.max(1, floor(sy)))
  local total = nx * ny

  for oy = 0, oh - 1 do
    for ox = 0, ow - 1 do
      -- Weighted by alpha: averaging a transparent pixel's color channels in
      -- would drag edges toward whatever happens to sit in the unused RGB of
      -- fully transparent source pixels, usually black.
      local acc, g, b, a = 0, 0, 0, 0
      for j = 0, ny - 1 do
        local py = floor(oy * sy + (j + 0.5) * sy / ny)
        if py >= sh then py = sh - 1 end
        for i = 0, nx - 1 do
          local px = floor(ox * sx + (i + 0.5) * sx / nx)
          if px >= sw then px = sw - 1 end
          local p  = src:getPixel(px, py)
          local pa = rgbaA(p)
          acc = acc + rgbaR(p) * pa
          g   = g + rgbaG(p) * pa
          b   = b + rgbaB(p) * pa
          a   = a + pa
        end
      end
      if a > 0 then
        out:putPixel(ox, oy, rgba(
          floor(acc / a + 0.5), floor(g / a + 0.5), floor(b / a + 0.5),
          floor(a / total + 0.5)))
      end
    end
  end
  return out
end

----------------------------------------------------------------------
-- Quantization (median cut)
--
-- Splits the color cloud along its longest axis at the population median,
-- repeatedly. Colors end up spent where the image actually has detail, rather
-- than spread evenly through a cube most of the image never visits.

local function boxStats(box)
  local rmin, gmin, bmin = 255, 255, 255
  local rmax, gmax, bmax = 0, 0, 0
  local count = 0
  for i = 1, #box do
    local e = box[i]
    if e.r < rmin then rmin = e.r end
    if e.r > rmax then rmax = e.r end
    if e.g < gmin then gmin = e.g end
    if e.g > gmax then gmax = e.g end
    if e.b < bmin then bmin = e.b end
    if e.b > bmax then bmax = e.b end
    count = count + e.n
  end

  local dr, dg, db = rmax - rmin, gmax - gmin, bmax - bmin
  -- Luma weights. The eye resolves green detail far better than blue, so an
  -- equal numeric spread in blue earns fewer palette entries than one in green.
  local wr, wg, wb = dr * 0.30, dg * 0.59, db * 0.11
  if wr >= wg and wr >= wb then
    box.axis, box.range = "r", dr
  elseif wg >= wb then
    box.axis, box.range = "g", dg
  else
    box.axis, box.range = "b", db
  end

  box.count = count
  box.score = box.range * count
  return box
end

local function splitBox(box)
  local axis = box.axis
  table.sort(box, function(p, q) return p[axis] < q[axis] end)

  local half, acc, cut = box.count / 2, 0, 1
  for i = 1, #box do
    acc = acc + box[i].n
    if acc >= half then
      cut = i
      break
    end
  end
  -- Both halves must be non-empty or the loop that called us cannot make
  -- progress and the palette silently comes back short.
  if cut >= #box then cut = #box - 1 end
  if cut < 1 then cut = 1 end

  local lo, hi = {}, {}
  for i = 1, cut do lo[#lo + 1] = box[i] end
  for i = cut + 1, #box do hi[#hi + 1] = box[i] end
  return boxStats(lo), boxStats(hi)
end

-- Returns a new image plus the palette it was reduced to.
--
-- `hard` (default true) forces every surviving pixel fully opaque and drops
-- everything below `alphaCut`, because a soft edge is the one thing that most
-- reliably stops a small image reading as pixel art. Pass false to keep the
-- source's own alpha and only quantize color.
function convert.quantize(img, k, alphaCut, hard)
  hard = (hard ~= false)
  local out = img:clone()
  local seen, colors = {}, {}

  for it in out:pixels() do
    local p = it()
    if rgbaA(p) >= alphaCut then
      local r, g, b = rgbaR(p), rgbaG(p), rgbaB(p)
      local key = r * 65536 + g * 256 + b
      local e = seen[key]
      if e then
        e.n = e.n + 1
      else
        e = { r = r, g = g, b = b, n = 1 }
        seen[key] = e
        colors[#colors + 1] = e
      end
    end
  end

  if #colors == 0 then
    out:clear(0)
    return out, {}
  end

  local boxes = { boxStats(colors) }
  while #boxes < k do
    local best, at
    for i = 1, #boxes do
      local box = boxes[i]
      if #box > 1 and box.range > 0 and (not best or box.score > best.score) then
        best, at = box, i
      end
    end
    if not best then break end

    local lo, hi = splitBox(best)
    if #lo == 0 or #hi == 0 then break end
    boxes[at] = lo
    boxes[#boxes + 1] = hi
  end

  local map, palette = {}, {}
  for i = 1, #boxes do
    local box = boxes[i]
    local r, g, b, n = 0, 0, 0, 0
    for j = 1, #box do
      local e = box[j]
      r = r + e.r * e.n
      g = g + e.g * e.n
      b = b + e.b * e.n
      n = n + e.n
    end
    local cr, cg, cb = floor(r / n + 0.5), floor(g / n + 0.5), floor(b / n + 0.5)
    palette[#palette + 1] = { r = cr, g = cg, b = cb }

    local packed = rgba(cr, cg, cb, 255)
    for j = 1, #box do
      local e = box[j]
      map[e.r * 65536 + e.g * 256 + e.b] = packed
    end
  end

  for it in out:pixels() do
    local p = it()
    local a = rgbaA(p)
    if a < alphaCut then
      it(0)
    else
      local m = map[rgbaR(p) * 65536 + rgbaG(p) * 256 + rgbaB(p)]
      -- Palette entries are stored opaque, so soft mode has to put the
      -- source's own alpha back on the way out.
      if hard then
        it(m)
      else
        it(rgba(rgbaR(m), rgbaG(m), rgbaB(m), a))
      end
    end
  end

  return out, palette
end

local function nearestInPalette(palette, r, g, b)
  local best, bestDist = palette[1], math.huge
  for i = 1, #palette do
    local c = palette[i]
    local dr, dg, db = r - c.r, g - c.g, b - c.b
    -- Same luma weighting as the median cut's split axis, for the same reason.
    local d = 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
    if d < bestDist then best, bestDist = c, d end
  end
  return best
end

-- Snap every pixel to the nearest entry of a palette chosen elsewhere, instead
-- of deriving one from the image. This is what "use current palette" runs: the
-- point is that the import comes back in colors the sprite already owns, so it
-- sits alongside existing artwork rather than beside it.
function convert.applyPalette(img, palette, alphaCut, hard)
  hard = (hard ~= false)
  local out = img:clone()
  if not palette or #palette == 0 then return out, {} end

  local cache = {}
  for it in out:pixels() do
    local p = it()
    local a = rgbaA(p)
    if a < alphaCut then
      it(0)
    else
      local r, g, b = rgbaR(p), rgbaG(p), rgbaB(p)
      local key = r * 65536 + g * 256 + b
      local c = cache[key]
      if not c then
        c = nearestInPalette(palette, r, g, b)
        cache[key] = c
      end
      it(rgba(c.r, c.g, c.b, hard and 255 or a))
    end
  end
  return out, palette
end

-- Choose at most `n` entries of `palette` that suit this image, so a color
-- limit and a borrowed palette can be used together.
--
-- Median cut picks the n colors the image actually wants, then each of those
-- is snapped to the nearest color the sprite really has. Doing it the other
-- way round - ranking the sprite's entries by how much area they cover - would
-- spend the whole budget on backgrounds and drop small bright details.
--
-- The result can come back shorter than n when two wanted colors land on the
-- same entry. That is honest: the sprite genuinely has no third color there.
function convert.subsetPalette(img, palette, n, alphaCut)
  local _, wanted = convert.quantize(img, n, alphaCut or 128, true)
  if not wanted or #wanted == 0 then return palette end

  local seen, out = {}, {}
  for _, c in ipairs(wanted) do
    local m = nearestInPalette(palette, c.r, c.g, c.b)
    local key = m.r * 65536 + m.g * 256 + m.b
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = m
    end
  end
  return out
end

-- The palette the artist can see in the color bar. Works in every color
-- mode: Aseprite keeps a palette on RGB sprites too.
function convert.paletteFromSprite(sprite)
  local out = {}
  local pal = sprite.palettes[1]
  if not pal then return out end

  -- The transparent index is a slot, not a color; mapping onto it would turn
  -- opaque pixels invisible.
  local skip = (sprite.colorMode == ColorMode.INDEXED) and sprite.transparentColor or nil

  for i = 0, #pal - 1 do
    if i ~= skip then
      local c = pal:getColor(i)
      if c.alpha > 0 then
        out[#out + 1] = { r = c.red, g = c.green, b = c.blue }
      end
    end
  end
  return out
end

-- The same alpha decision without touching color, for when the artist wants
-- the full color range but still wants a clean silhouette.
function convert.hardenAlpha(img, alphaCut)
  for it in img:pixels() do
    local p = it()
    local a = rgbaA(p)
    if a > 0 then
      if a < alphaCut then
        it(0)
      else
        it(rgba(rgbaR(p), rgbaG(p), rgbaB(p), 255))
      end
    end
  end
  return img
end

----------------------------------------------------------------------
-- Native resolution detection
--
-- A 32x32 sprite exported as a 512x512 png is still a 32x32 sprite; the file
-- just carries every pixel sixteen times over. Finding that factor lets the
-- import recover the original exactly instead of averaging it back into mush.

-- Per-channel slack for "the same color". Not zero, because a png that has
-- been through a lossy round trip still deserves to be recognized.
local TOL = 12

-- Nearly every block must be flat before we believe in a grid. Photographs
-- fail this immediately at any factor worth having.
local UNIFORM_MIN = 0.98

-- And some blocks must actually differ from their neighbor. Without this a
-- smooth gradient reads as a grid of flat blocks at small factors.
local EDGE_MIN = 0.05

local SAMPLE_BLOCKS = 400
local MAX_DETECT = 64

local function gcd(a, b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

local function sameColor(p, q)
  return math.abs(rgbaR(p) - rgbaR(q)) <= TOL
     and math.abs(rgbaG(p) - rgbaG(q)) <= TOL
     and math.abs(rgbaB(p) - rgbaB(q)) <= TOL
     and math.abs(rgbaA(p) - rgbaA(q)) <= TOL
end

-- Walks a sampled subset of the grid, so cost is flat regardless of how big
-- the image is or how small the candidate factor is.
local function eachSampledBlock(img, k, fn)
  local bx = floor(img.width / k)
  local by = floor(img.height / k)
  local total = bx * by
  if total < 1 then return 0 end

  local step = math.max(1, floor(total / SAMPLE_BLOCKS))
  local seen = 0
  local i = 0
  while i < total do
    fn(i % bx, floor(i / bx), bx, by)
    seen = seen + 1
    i = i + step
  end
  return seen
end

local function blocksAreFlat(img, k)
  local flat = 0
  local probes = math.min(k, 4)

  local seen = eachSampledBlock(img, k, function(bxi, byi)
    local ox, oy = bxi * k, byi * k
    local ref = img:getPixel(ox, oy)
    local ok = true

    for j = 0, probes - 1 do
      local py = oy + floor(j * k / probes)
      for i = 0, probes - 1 do
        if not sameColor(img:getPixel(ox + floor(i * k / probes), py), ref) then
          ok = false
          break
        end
      end
      if not ok then break end
    end

    -- The far corner specifically: a coarse probe grid can straddle a real
    -- boundary and miss it.
    if ok and not sameColor(img:getPixel(ox + k - 1, oy + k - 1), ref) then
      ok = false
    end
    if ok then flat = flat + 1 end
  end)

  return seen > 0 and (flat / seen) >= UNIFORM_MIN
end

local function blocksDiffer(img, k)
  local pairs_, jumps = 0, 0

  eachSampledBlock(img, k, function(bxi, byi, bx)
    if bxi >= bx - 1 then return end
    local a = img:getPixel(bxi * k, byi * k)
    local b = img:getPixel((bxi + 1) * k, byi * k)
    pairs_ = pairs_ + 1
    if not sameColor(a, b) then jumps = jumps + 1 end
  end)

  return pairs_ > 0 and (jumps / pairs_) >= EDGE_MIN
end

-- The integer factor this image has been blown up by, or 1 if it has not been.
-- Largest factor first, because a 16x upscale is also trivially a 2x, 4x and
-- 8x one and only the largest recovers the real artwork.
function convert.detectScale(img, maxFactor)
  maxFactor = maxFactor or MAX_DETECT
  local w, h = img.width, img.height
  local g = gcd(w, h)
  if g < 2 then return 1 end

  for k = math.min(g, maxFactor), 2, -1 do
    -- A factor that leaves almost nothing behind is not a discovery, it is a
    -- coincidence.
    if g % k == 0 and w / k >= 4 and h / k >= 4 then
      if blocksAreFlat(img, k) and blocksDiffer(img, k) then
        return k
      end
    end
  end
  return 1
end

-- Collapse a detected grid by taking one pixel per block rather than averaging.
-- Averaging would reintroduce exactly the intermediate colors the upscale had
-- already flattened away.
function convert.blockReduce(img, k)
  local ow = floor(img.width / k)
  local oh = floor(img.height / k)
  local out = Image(ow, oh, ColorMode.RGB)
  local mid = floor(k / 2)
  for y = 0, oh - 1 do
    for x = 0, ow - 1 do
      out:putPixel(x, y, img:getPixel(x * k + mid, y * k + mid))
    end
  end
  return out
end

----------------------------------------------------------------------
-- Output size
--
-- One slider, 1 to 100, where 100 is as large as this source can honestly go
-- and 1 is a single pixel. Linear, so 50 is half of the maximum.

-- The largest output this source can honestly produce: never above the
-- ceiling, and never larger than the working copy actually holds, because past
-- that we would be inventing detail rather than reducing it. That second limit
-- is what keeps a 512px file that is really a 32px sprite from being blown
-- back up to 256.
function convert.maxOutputLong(source)
  local long = math.max(source.width, source.height)
  if source.image then
    long = math.min(long, math.max(source.image.width, source.image.height))
  end
  return math.max(1, math.min(MAX_OUTPUT, long))
end

-- The output dimensions for a scale of 1..100, keeping the source's shape.
function convert.sizeForScale(source, scale)
  scale = math.max(1, math.min(100, scale or 100))
  local long = math.max(1, floor(convert.maxOutputLong(source) * scale / 100 + 0.5))

  local w, h = source.width, source.height
  if w >= h then
    return long, math.max(1, floor(long * h / w + 0.5))
  end
  return math.max(1, floor(long * w / h + 0.5)), long
end

-- The scale setting that corresponds to a given output long side. The inverse
-- of sizeForScale, for keeping the slider in step with a size typed by hand.
function convert.scaleForSize(source, long)
  local maxLong = convert.maxOutputLong(source)
  if maxLong < 1 then return 100 end
  return math.max(1, math.min(100, floor(long / maxLong * 100 + 0.5)))
end

-- Where the scale slider should start for this source.
local TARGET_LONG_SIDE = 128

function convert.suggest(source)
  -- Upscaled art has a right answer, not a taste-based one: its own native
  -- resolution, which is exactly what the working copy already holds.
  if source.scale and source.scale > 1 then return 100 end

  local maxLong = convert.maxOutputLong(source)
  return math.max(1, math.min(100, floor(TARGET_LONG_SIDE / maxLong * 100 + 0.5)))
end

----------------------------------------------------------------------
-- Loading

-- Returns { image, width, height, path, name }, where `image` may be a capped
-- working copy and width/height are always the true source dimensions. Pixel
-- size is quoted against the original, so the number the artist types keeps
-- meaning the same thing whether or not the cap kicked in.
-- Flatten one frame of a sprite into straight RGBA.
function convert.imageFromSprite(spr, frame)
  frame = frame or 1
  local empty = (spr.colorMode == ColorMode.INDEXED) and spr.transparentColor or 0
  local flat  = Image(spr.width, spr.height, spr.colorMode)
  flat:clear(empty)
  flat:drawSprite(spr, frame)

  if spr.colorMode == ColorMode.INDEXED then
    return fromIndexed(flat, spr.palettes[1], spr.transparentColor)
  elseif spr.colorMode == ColorMode.GRAY then
    return fromGray(flat)
  end
  return flat
end

-- The tail shared by every import route: find the native grid, cap the working
-- copy, package it up.
local function packageSource(img, path, name)
  local w, h = img.width, img.height

  -- Before any capping: the cap resamples, and resampling destroys the very
  -- grid we are looking for.
  local scale = convert.detectScale(img)
  if scale > 1 then
    img = convert.blockReduce(img, scale)
  end

  local longest = math.max(img.width, img.height)
  if longest > MAX_SOURCE then
    local s = MAX_SOURCE / longest
    -- One-off cost, so it gets a far bigger sampling budget than a live pass.
    img = convert.resample(img, floor(img.width * s + 0.5), floor(img.height * s + 0.5), 8000000)
  end

  return {
    image  = img,
    width  = w,        -- always the source's own dimensions
    height = h,
    scale  = scale,    -- 1 unless the source is upscaled pixel art
    path   = path,
    name   = name,
  }
end

-- Import one frame of a sprite that is already open. This is the route the
-- Import button takes: Aseprite's own Open dialog hands back sprites, not
-- paths, and a file that arrived as a sequence or a gif is one sprite holding
-- several images, so the frame has to be part of the request.
function convert.fromSprite(spr, frame)
  frame = frame or 1
  local name = "Imported"
  if spr.filename and spr.filename ~= "" then
    name = app.fs.fileTitle(spr.filename)
  end
  local src = packageSource(convert.imageFromSprite(spr, frame), spr.filename, name)

  -- The frame is recorded rather than baked into the name: the dropdown
  -- already numbers its entries, so "10. eclipse (10)" says it twice. It is
  -- still wanted when naming a layer, where there is no number to lean on.
  if #spr.frames > 1 then src.frame = frame end
  return src
end

-- Import straight from a path, without disturbing the open tabs where possible.
function convert.load(path)
  if not path or path == "" then return nil, "No file selected." end
  if not app.fs.isFile(path) then
    return nil, "No file at " .. tostring(path)
  end

  local ext = app.fs.fileExtension(path):lower()
  local img

  -- Image{fromFile} is cheap and leaves the open tabs alone, but it hands back
  -- no palette and does not composite layers. Use it only where neither
  -- matters: a flat format that loaded as RGB already.
  if FLAT_FORMATS[ext] then
    local ok, loaded = pcall(function() return Image{ fromFile = path } end)
    if ok and loaded and loaded.colorMode == ColorMode.RGB then
      img = loaded
    end
  end

  if not img then
    local previous = app.sprite
    local ok, spr = pcall(function() return Sprite{ fromFile = path } end)
    if not ok or not spr then
      return nil, "Aseprite could not read " .. app.fs.fileName(path)
    end

    img = convert.imageFromSprite(spr)
    spr:close()
    -- Closing our scratch sprite makes some other tab active; put the artist
    -- back where they were.
    if previous then pcall(function() app.sprite = previous end) end
  end

  return packageSource(img, path, app.fs.fileTitle(path))
end

----------------------------------------------------------------------

-- Color reduction. A borrowed palette and a color count are not rivals: the
-- palette says which colors are allowed, the count says how many of them to
-- spend. Given both, the count narrows the palette rather than replacing it.
local function reduceColors(img, opts)
  local hard = (opts.hard ~= false)
  local cut  = opts.alphaCut or (hard and 128 or 1)

  if opts.palette and #opts.palette > 0 then
    local pal = opts.palette
    if opts.colors and opts.colors < #pal then
      pal = convert.subsetPalette(img, pal, opts.colors, cut)
    end
    return convert.applyPalette(img, pal, cut, hard)
  elseif opts.colors then
    return convert.quantize(img, opts.colors, cut, hard)
  elseif hard then
    convert.hardenAlpha(img, cut)
  end
  return img, nil
end

-- One full conversion. `opts.pixelSize` is how many source pixels collapse
-- into one output pixel; `opts.colors` nil means leave color alone.
function convert.run(source, opts)
  local ow, oh
  if opts.targetW and opts.targetH then
    -- An explicit size is honored as given, including a ratio that does not
    -- match the source: squashing on purpose is a legitimate thing to want.
    ow = math.max(1, floor(opts.targetW))
    oh = math.max(1, floor(opts.targetH))
  else
    ow, oh = convert.sizeForScale(source, opts.scale)
  end

  -- A typed size is still held to the same ceiling as the slider.
  local limit = convert.maxOutputLong(source)
  local longest = math.max(ow, oh)
  if longest > limit then
    local s = limit / longest
    ow = math.max(1, floor(ow * s + 0.5))
    oh = math.max(1, floor(oh * s + 0.5))
  end

  return reduceColors(convert.resample(source.image, ow, oh, nil, opts.method), opts)
end

-- Match a destination sprite's color mode. An RGB image dropped into an
-- indexed sprite has to be routed through that sprite's palette, or its pixel
-- values get read as arbitrary indices and the result is confetti.
function convert.forSprite(img, sprite)
  local mode = sprite.colorMode
  if mode == ColorMode.RGB then return img:clone() end

  if mode == ColorMode.GRAY then
    local out = Image(img.width, img.height, ColorMode.GRAY)
    out:clear(0)
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local p = img:getPixel(x, y)
        local a = rgbaA(p)
        if a > 0 then
          local v = floor(0.30 * rgbaR(p) + 0.59 * rgbaG(p) + 0.11 * rgbaB(p) + 0.5)
          out:putPixel(x, y, pc.graya(v, a))
        end
      end
    end
    return out
  end

  local pal = sprite.palettes[1]
  local ti  = sprite.transparentColor
  local out = Image(img.width, img.height, ColorMode.INDEXED)
  out:clear(ti)

  -- A quantized image has at most a few dozen distinct colors, so caching the
  -- palette search turns a per-pixel scan into a per-color one.
  local cache = {}
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local p = img:getPixel(x, y)
      if rgbaA(p) > 0 then
        local r, g, b = rgbaR(p), rgbaG(p), rgbaB(p)
        local key = r * 65536 + g * 256 + b
        local idx = cache[key]
        if not idx then
          idx = convert.nearestIndex(pal, r, g, b, ti)
          cache[key] = idx
        end
        out:putPixel(x, y, idx)
      end
    end
  end
  return out
end

function convert.nearestIndex(pal, r, g, b, skip)
  local best, bestDist = 0, math.huge
  for i = 0, #pal - 1 do
    if i ~= skip then
      local c = pal:getColor(i)
      if c.alpha > 0 then
        local dr, dg, db = r - c.red, g - c.green, b - c.blue
        -- Same luma weighting as the split axis, for the same reason.
        local d = 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
        if d < bestDist then best, bestDist = i, d end
      end
    end
  end
  return best
end

return convert
