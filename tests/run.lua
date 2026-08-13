-- Headless test suite.
--   Aseprite.exe -b --script pixelimport\tests\run.lua
-- Results are written next to this file as run.results.txt, because Aseprite
-- on Windows does not attach stdout to the console.

local ROOT = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local SRC  = ROOT .. "/../src"

local convert = dofile(SRC .. "/convert.lua")
local place   = dofile(SRC .. "/place.lua")

local log, passed, failed = {}, 0, 0

local function record(ok, name, detail)
  if ok then
    passed = passed + 1
    log[#log + 1] = "  PASS  " .. name
  else
    failed = failed + 1
    local msg = tostring(detail):match("^[^\n]*") or tostring(detail)
    log[#log + 1] = "  FAIL  " .. name .. "  -> " .. msg
  end
end

local function check(name, fn)
  local ok, err = pcall(fn)
  record(ok, name, err)
end

local function assertEq(got, want, what)
  if got ~= want then
    error(string.format("%s: got %s, want %s", what or "value", tostring(got), tostring(want)), 2)
  end
end

local function assertTrue(v, what)
  if not v then error(what or "expected true", 2) end
end

local function section(title) log[#log + 1] = "" ; log[#log + 1] = title end

local rgba  = app.pixelColor.rgba
local rgbaA = app.pixelColor.rgbaA

-- A photo-ish source: a smooth gradient plus a hard-edged shape, so both the
-- resampler and the quantizer have something real to chew on. Asymmetric,
-- because symmetric test images hide flip and offset bugs.
local function makeSource(w, h)
  w, h = w or 128, h or 96
  local s = Sprite(w, h, ColorMode.RGB)
  local img = s.cels[1].image
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r = math.floor(255 * x / (w - 1))
      local g = math.floor(255 * y / (h - 1))
      img:putPixel(x, y, rgba(r, g, 128, 255))
    end
  end
  -- Opaque blob off-center, and a transparent notch.
  for y = 10, 30 do
    for x = 12, 40 do img:putPixel(x, y, rgba(255, 0, 0, 255)) end
  end
  for y = 60, 80 do
    for x = 70, 100 do img:putPixel(x, y, rgba(0, 0, 0, 0)) end
  end
  return s
end

local function uniqueColors(img)
  local seen, n = {}, 0
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local p = img:getPixel(x, y)
      if rgbaA(p) > 0 then
        local key = p
        if not seen[key] then seen[key] = true ; n = n + 1 end
      end
    end
  end
  return n
end

local function tmpFile(name)
  return app.fs.joinPath(ROOT, name)
end

-- Blocky, hard-edged, high-frequency: what upscaled sprite art looks like, and
-- the opposite of a photograph in every way detection cares about.
local function makePixelArt(w, h)
  w, h = w or 16, h or 16
  local s = Sprite(w, h, ColorMode.RGB)
  local img = s.cels[1].image
  local pal = {
    rgba(0, 0, 0, 0),
    rgba(230, 40, 40, 255),
    rgba(40, 200, 90, 255),
    rgba(50, 80, 240, 255),
    rgba(250, 240, 60, 255),
  }
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      img:putPixel(x, y, pal[((x * 7 + y * 13) % 5) + 1])
    end
  end
  return s
end

local function upscale(img, k)
  local out = Image(img.width * k, img.height * k, ColorMode.RGB)
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      out:putPixel(x, y, img:getPixel(math.floor(x / k), math.floor(y / k)))
    end
  end
  return out
end

-- An indexed sprite with a palette we control.
--
-- ChangePixelFormat is not used here on purpose: in batch mode it hands back a
-- 256-entry all-black palette, so a test built on it would be measuring
-- Aseprite's conversion defaults rather than this code.
--
-- The bands are three pixels wide, deliberately. Even-width bands would make
-- this image a genuine 2x grid, native-resolution detection would fire on it,
-- and a test about palette decoding would start failing for reasons that have
-- nothing to do with palettes.
local function makeIndexedSprite(w, h)
  local s = Sprite(w or 8, h or 8, ColorMode.INDEXED)
  local pal = Palette(4)
  pal:setColor(0, Color{ r = 0,   g = 0,   b = 0,   a = 0 })    -- transparent
  pal:setColor(1, Color{ r = 255, g = 0,   b = 0,   a = 255 })
  pal:setColor(2, Color{ r = 0,   g = 255, b = 0,   a = 255 })
  pal:setColor(3, Color{ r = 0,   g = 0,   b = 255, a = 255 })
  s:setPalette(pal)

  local img = s.cels[1].image
  img:clear(1)
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      if x < 3 then
        img:putPixel(x, y, 0)          -- a transparent stripe
      elseif y < 3 then
        img:putPixel(x, y, 2)
      elseif y > img.height - 4 then
        img:putPixel(x, y, 3)
      end
    end
  end
  return s
end

----------------------------------------------------------------------
section("resample")

check("resample hits the requested size exactly", function()
  local s = makeSource()
  local out = convert.resample(s.cels[1].image, 32, 24)
  assertEq(out.width, 32, "width")
  assertEq(out.height, 24, "height")
  assertEq(out.colorMode, ColorMode.RGB, "color mode")
  s:close()
end)

check("resample never returns a zero dimension", function()
  local s = makeSource()
  local out = convert.resample(s.cels[1].image, 0, 0)
  assertEq(out.width, 1, "width")
  assertEq(out.height, 1, "height")
  s:close()
end)

check("resample keeps fully transparent regions transparent", function()
  local s = makeSource()
  -- The notch spans 70..100 x 60..80 of a 128x96 source; at 1/4 scale its
  -- interior is comfortably inside 18..25 x 16..20.
  local out = convert.resample(s.cels[1].image, 32, 24)
  assertEq(rgbaA(out:getPixel(21, 18)), 0, "notch alpha")
  s:close()
end)

check("resample keeps opaque regions opaque", function()
  local s = makeSource()
  local out = convert.resample(s.cels[1].image, 32, 24)
  assertEq(rgbaA(out:getPixel(6, 5)), 255, "blob alpha")
  s:close()
end)

check("resample upscales without crashing", function()
  local s = makeSource(16, 16)
  local out = convert.resample(s.cels[1].image, 64, 64)
  assertEq(out.width, 64, "width")
  s:close()
end)

----------------------------------------------------------------------
section("downscale methods")

local ALL_METHODS = { "area", "nearest", "bilinear", "bicubic" }

check("every method hits the requested size", function()
  local s = makeSource()
  for _, m in ipairs(ALL_METHODS) do
    local out = convert.resample(s.cels[1].image, 32, 24, nil, m)
    assertEq(out.width, 32, m .. " width")
    assertEq(out.height, 24, m .. " height")
  end
  s:close()
end)

check("every method leaves a flat color untouched", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local want = rgba(37, 111, 203, 255)
  s.cels[1].image:clear(want)
  for _, m in ipairs(ALL_METHODS) do
    local out = convert.resample(s.cels[1].image, 8, 8, nil, m)
    for y = 0, 7 do
      for x = 0, 7 do
        assertEq(out:getPixel(x, y), want, m .. " drifted at " .. x .. "," .. y)
      end
    end
  end
  s:close()
end)

check("every method is exact at 1:1", function()
  local art = makePixelArt(16, 16)
  local src = art.cels[1].image
  for _, m in ipairs(ALL_METHODS) do
    local out = convert.resample(src, 16, 16, nil, m)
    for y = 0, 15 do
      for x = 0, 15 do
        assertEq(out:getPixel(x, y), src:getPixel(x, y), m .. " at " .. x .. "," .. y)
      end
    end
  end
  art:close()
end)

check("nearest neighbor invents no color that was not in the source", function()
  local s = makeSource()
  local src = s.cels[1].image
  local seen = {}
  for y = 0, src.height - 1 do
    for x = 0, src.width - 1 do seen[src:getPixel(x, y)] = true end
  end

  local out = convert.resample(src, 32, 24, nil, "nearest")
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      assertTrue(seen[out:getPixel(x, y)], "invented a color at " .. x .. "," .. y)
    end
  end
  s:close()
end)

check("the smoothing methods do invent colors - that is the point", function()
  local s = makeSource()
  local src = s.cels[1].image
  local seen = {}
  for y = 0, src.height - 1 do
    for x = 0, src.width - 1 do seen[src:getPixel(x, y)] = true end
  end

  local nearest = convert.resample(src, 32, 24, nil, "nearest")
  for _, m in ipairs{ "area", "bilinear", "bicubic" } do
    local out = convert.resample(src, 32, 24, nil, m)
    local differs = false
    for y = 0, out.height - 1 do
      for x = 0, out.width - 1 do
        if out:getPixel(x, y) ~= nearest:getPixel(x, y) then differs = true end
      end
    end
    assertTrue(differs, m .. " produced exactly the nearest-neighbor result")
  end
  s:close()
end)

check("every method keeps transparent regions transparent", function()
  local s = makeSource()
  for _, m in ipairs(ALL_METHODS) do
    local out = convert.resample(s.cels[1].image, 32, 24, nil, m)
    assertEq(rgbaA(out:getPixel(21, 18)), 0, m .. " leaked into the notch")
  end
  s:close()
end)

check("an unknown method falls back to area rather than failing", function()
  local s = makeSource()
  local a = convert.resample(s.cels[1].image, 16, 12, nil, "area")
  local b = convert.resample(s.cels[1].image, 16, 12, nil, "no such filter")
  for y = 0, 11 do
    for x = 0, 15 do
      assertEq(b:getPixel(x, y), a:getPixel(x, y), "fallback differs at " .. x .. "," .. y)
    end
  end
  s:close()
end)

check("methodByLabel round-trips every menu entry", function()
  local labels = convert.methodLabels()
  assertEq(#labels, #convert.methods, "label count")
  for i, m in ipairs(convert.methods) do
    assertEq(convert.methodByLabel(labels[i]), m.id, "label " .. labels[i])
  end
  -- An unrecognized label falls back to the menu default, not to whichever
  -- filter happens to be named in the code.
  assertEq(convert.methodByLabel("nonsense"), convert.methods[1].id, "fallback")
  assertEq(convert.methods[1].id, "nearest", "nearest should be the default")
end)

check("run passes the method through", function()
  local s = makeSource(128, 96)
  local src = { image = s.cels[1].image, width = 128, height = 96, scale = 1 }
  -- An actual reduction: at scale 100 the resample is 1:1, where every filter
  -- is exact and therefore identical.
  local near = convert.run(src, { scale = 25, colors = nil, method = "nearest" })
  local area = convert.run(src, { scale = 25, colors = nil, method = "area" })

  local differs = false
  for y = 0, near.height - 1 do
    for x = 0, near.width - 1 do
      if near:getPixel(x, y) ~= area:getPixel(x, y) then differs = true end
    end
  end
  assertTrue(differs, "method had no effect")
  s:close()
end)

----------------------------------------------------------------------
section("explicit target size")

check("run honors a target size exactly", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  local out = convert.run(src, { scale = 100, targetW = 40, targetH = 25, colors = nil })
  assertEq(out.width, 40, "width")
  assertEq(out.height, 25, "height")
  s:close()
end)

check("a target size overrides pixel size", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  local sized = convert.run(src, { scale = 100, targetW = 16, targetH = 12, colors = nil })
  assertEq(sized.width, 16, "pixel size should have been ignored")
  s:close()
end)

check("a target size may distort on purpose", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  local out = convert.run(src, { scale = 100, targetW = 64, targetH = 8, colors = nil })
  assertEq(out.width, 64, "width")
  assertEq(out.height, 8, "squashing is a legitimate request")
  s:close()
end)

check("a target size is still clamped by how much source there is", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  local out = convert.run(src, { scale = 100, targetW = 4000, targetH = 3000, colors = nil })
  assertTrue(out.width <= 512, "should be capped, got " .. out.width)
  s:close()
end)

check("a target size below one is refused rather than crashing", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  local out = convert.run(src, { scale = 100, targetW = 0, targetH = -5, colors = nil })
  assertTrue(out.width >= 1 and out.height >= 1, "degenerate size")
  s:close()
end)

----------------------------------------------------------------------
section("quantize")

check("quantize respects the color ceiling", function()
  local s = makeSource()
  local small = convert.resample(s.cels[1].image, 64, 48)
  for _, k in ipairs{ 2, 4, 8, 16, 32 } do
    local out = convert.quantize(small, k, 128)
    local n = uniqueColors(out)
    assertTrue(n <= k, string.format("k=%d produced %d colors", k, n))
    assertTrue(n > 0, "k=" .. k .. " produced nothing")
  end
  s:close()
end)

check("quantize actually uses the budget it is given", function()
  local s = makeSource()
  local small = convert.resample(s.cels[1].image, 64, 48)
  local out = convert.quantize(small, 16, 128)
  -- A full-range gradient should fill the palette, not collapse to a handful.
  assertTrue(uniqueColors(out) >= 12, "only " .. uniqueColors(out) .. " colors from a gradient")
  s:close()
end)

check("quantize returns a palette matching the image", function()
  local s = makeSource()
  local small = convert.resample(s.cels[1].image, 48, 36)
  local out, pal = convert.quantize(small, 8, 128)
  assertTrue(pal ~= nil and #pal > 0, "no palette returned")
  assertTrue(#pal <= 8, "palette too big: " .. #pal)
  local allowed = {}
  for _, c in ipairs(pal) do allowed[rgba(c.r, c.g, c.b, 255)] = true end
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      local p = out:getPixel(x, y)
      if rgbaA(p) > 0 then
        assertTrue(allowed[p], "pixel at " .. x .. "," .. y .. " is not in the palette")
      end
    end
  end
  s:close()
end)

check("quantize leaves alpha binary", function()
  local s = makeSource()
  local small = convert.resample(s.cels[1].image, 64, 48)
  local out = convert.quantize(small, 16, 128)
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      local a = rgbaA(out:getPixel(x, y))
      assertTrue(a == 0 or a == 255, "partial alpha " .. a .. " at " .. x .. "," .. y)
    end
  end
  s:close()
end)

check("quantize copes with fewer source colors than requested", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(10, 20, 30, 255))
  local out = convert.quantize(img, 32, 128)
  assertEq(uniqueColors(out), 1, "color count")
  s:close()
end)

check("quantize copes with a fully transparent image", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local out = convert.quantize(s.cels[1].image, 16, 128)
  assertEq(uniqueColors(out), 0, "color count")
  s:close()
end)

check("quantize does not mutate its input", function()
  local s = makeSource()
  local small = convert.resample(s.cels[1].image, 32, 24)
  local before = uniqueColors(small)
  convert.quantize(small, 4, 128)
  assertEq(uniqueColors(small), before, "source was modified")
  s:close()
end)

-- Hard edges has to survive quantization. Palette entries are stored opaque,
-- so without an explicit soft path the color limit silently forces binary
-- alpha and the control does nothing at its default setting.
check("quantize honors soft edges even with a color limit", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(200, 50, 50, 255))
  img:putPixel(0, 0, rgba(200, 50, 50, 90))

  local hard = convert.quantize(img, 4, 128, true)
  assertEq(rgbaA(hard:getPixel(0, 0)), 0, "90 is below the cut, so it goes")

  local soft = convert.quantize(img, 4, 1, false)
  assertEq(rgbaA(soft:getPixel(0, 0)), 90, "alpha must survive")
  assertEq(rgbaA(soft:getPixel(4, 4)), 255, "opaque stays opaque")
  s:close()
end)

check("run passes hard edges through to the quantizer", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(200, 50, 50, 255))
  img:putPixel(0, 0, rgba(200, 50, 50, 90))
  local src = { image = img, width = 8, height = 8, scale = 1 }

  local hard = convert.run(src, { scale = 100, colors = 4, hard = true })
  assertEq(rgbaA(hard:getPixel(0, 0)), 0, "hard edges on")

  local soft = convert.run(src, { scale = 100, colors = 4, hard = false })
  assertEq(rgbaA(soft:getPixel(0, 0)), 90, "hard edges off")
  s:close()
end)

check("run honors hard edges with no color limit too", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(200, 50, 50, 255))
  img:putPixel(0, 0, rgba(200, 50, 50, 90))
  local src = { image = img, width = 8, height = 8, scale = 1 }

  local hard = convert.run(src, { scale = 100, colors = nil, hard = true })
  assertEq(rgbaA(hard:getPixel(0, 0)), 0, "hard edges on")

  local soft = convert.run(src, { scale = 100, colors = nil, hard = false })
  assertEq(rgbaA(soft:getPixel(0, 0)), 90, "hard edges off")
  s:close()
end)

check("hardenAlpha makes every pixel fully on or fully off", function()
  local s = Sprite(4, 4, ColorMode.RGB)
  local img = s.cels[1].image
  img:putPixel(0, 0, rgba(255, 0, 0, 200))
  img:putPixel(1, 0, rgba(255, 0, 0, 40))
  img:putPixel(2, 0, rgba(255, 0, 0, 0))
  convert.hardenAlpha(img, 128)
  assertEq(rgbaA(img:getPixel(0, 0)), 255, "above cut")
  assertEq(rgbaA(img:getPixel(1, 0)), 0, "below cut")
  assertEq(rgbaA(img:getPixel(2, 0)), 0, "already clear")
  s:close()
end)

----------------------------------------------------------------------
section("borrowed palettes")

check("paletteFromSprite reads an indexed sprite's colors", function()
  local s = makeIndexedSprite()
  local pal = convert.paletteFromSprite(s)
  assertEq(#pal, 3, "three usable colors, transparent slot excluded")
  s:close()
end)

check("paletteFromSprite skips the transparent index", function()
  local s = makeIndexedSprite()
  local pal = convert.paletteFromSprite(s)
  for _, c in ipairs(pal) do
    assertTrue(not (c.r == 0 and c.g == 0 and c.b == 0),
      "the transparent slot's color leaked in")
  end
  s:close()
end)

check("paletteFromSprite works on an RGB sprite too", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local pal = convert.paletteFromSprite(s)
  assertTrue(#pal > 0, "RGB sprites still carry a palette")
  s:close()
end)

check("applyPalette snaps every pixel onto the given colors", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(250, 5, 5, 255))
  img:putPixel(0, 0, rgba(5, 5, 250, 255))

  local pal = { { r = 255, g = 0, b = 0 }, { r = 0, g = 0, b = 255 } }
  local out = convert.applyPalette(img, pal, 128, true)
  assertEq(out:getPixel(4, 4), rgba(255, 0, 0, 255), "near-red snaps to red")
  assertEq(out:getPixel(0, 0), rgba(0, 0, 255, 255), "near-blue snaps to blue")
  s:close()
end)

check("applyPalette uses only colors from the palette", function()
  local s = makeSource(64, 48)
  local small = convert.resample(s.cels[1].image, 32, 24)
  local pal = { { r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 },
                { r = 255, g = 0, b = 0 } }
  local out = convert.applyPalette(small, pal, 128, true)

  local allowed = {}
  for _, c in ipairs(pal) do allowed[rgba(c.r, c.g, c.b, 255)] = true end
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      local p = out:getPixel(x, y)
      if rgbaA(p) > 0 then
        assertTrue(allowed[p], "off-palette color at " .. x .. "," .. y)
      end
    end
  end
  s:close()
end)

check("applyPalette keeps transparency", function()
  local s = Sprite(4, 4, ColorMode.RGB)   -- fully transparent
  local out = convert.applyPalette(s.cels[1].image, { { r = 255, g = 0, b = 0 } }, 128, true)
  assertEq(rgbaA(out:getPixel(0, 0)), 0, "transparent must stay transparent")
  s:close()
end)

check("applyPalette does not mutate its input", function()
  local s = Sprite(4, 4, ColorMode.RGB)
  local img = s.cels[1].image
  img:clear(rgba(250, 5, 5, 255))
  convert.applyPalette(img, { { r = 0, g = 255, b = 0 } }, 128, true)
  assertEq(img:getPixel(0, 0), rgba(250, 5, 5, 255), "source was modified")
  s:close()
end)

-- A borrowed palette and a color count are not rivals: the palette says which
-- colors are allowed, the count says how many of them to spend.
local function bigPalette(n)
  local pal = {}
  for i = 0, n - 1 do
    pal[#pal + 1] = { r = (i * 37) % 256, g = (i * 91) % 256, b = (i * 143) % 256 }
  end
  return pal
end

check("subsetPalette returns at most the requested count", function()
  local s = makeSource(64, 48)
  local small = convert.resample(s.cels[1].image, 32, 24)
  local pal = bigPalette(64)
  for _, n in ipairs{ 2, 4, 8, 16 } do
    local sub = convert.subsetPalette(small, pal, n, 128)
    assertTrue(#sub <= n, string.format("n=%d gave %d", n, #sub))
    assertTrue(#sub > 0, "n=" .. n .. " gave nothing")
  end
  s:close()
end)

check("subsetPalette only returns colors from the palette given", function()
  local s = makeSource(64, 48)
  local small = convert.resample(s.cels[1].image, 32, 24)
  local pal = bigPalette(64)

  local allowed = {}
  for _, c in ipairs(pal) do allowed[c.r * 65536 + c.g * 256 + c.b] = true end

  local sub = convert.subsetPalette(small, pal, 8, 128)
  for _, c in ipairs(sub) do
    assertTrue(allowed[c.r * 65536 + c.g * 256 + c.b], "invented a palette entry")
  end
  s:close()
end)

check("a color limit narrows a borrowed palette instead of replacing it", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  local pal = bigPalette(64)

  local allowed = {}
  for _, c in ipairs(pal) do allowed[rgba(c.r, c.g, c.b, 255)] = true end

  local out = convert.run(src, { scale = 100, colors = 8, palette = pal })

  local used = {}
  for y = 0, out.height - 1 do
    for x = 0, out.width - 1 do
      local p = out:getPixel(x, y)
      if rgbaA(p) > 0 then
        assertTrue(allowed[p], "a color appeared that is not in the palette")
        used[p] = true
      end
    end
  end

  local n = 0
  for _ in pairs(used) do n = n + 1 end
  assertTrue(n <= 8, "color limit ignored: " .. n .. " colors used")
  s:close()
end)

check("no color limit uses the whole borrowed palette", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  local pal = bigPalette(64)

  local limited = convert.run(src, { scale = 100, colors = 4, palette = pal })
  local full    = convert.run(src, { scale = 100, colors = nil, palette = pal })

  local function distinct(img)
    local seen, n = {}, 0
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local p = img:getPixel(x, y)
        if rgbaA(p) > 0 and not seen[p] then seen[p] = true ; n = n + 1 end
      end
    end
    return n
  end

  assertTrue(distinct(full) > distinct(limited),
    "an unlimited borrowed palette should use more colors than a limited one")
  s:close()
end)

check("a color count above the palette size changes nothing", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  local pal = bigPalette(4)

  local a = convert.run(src, { scale = 100, colors = 64, palette = pal })
  local b = convert.run(src, { scale = 100, colors = nil, palette = pal })
  for y = 0, a.height - 1 do
    for x = 0, a.width - 1 do
      assertEq(a:getPixel(x, y), b:getPixel(x, y), "differs at " .. x .. "," .. y)
    end
  end
  s:close()
end)

----------------------------------------------------------------------
section("snap positions")

check("cornerPosition puts the image flush against each corner", function()
  local s = Sprite(100, 80, ColorMode.RGB)
  local img = Image(20, 10, ColorMode.RGB)

  local tl = place.cornerPosition(s, img, "tl")
  assertEq(tl.x, 0, "tl x") ; assertEq(tl.y, 0, "tl y")
  local tr = place.cornerPosition(s, img, "tr")
  assertEq(tr.x, 80, "tr x") ; assertEq(tr.y, 0, "tr y")
  local bl = place.cornerPosition(s, img, "bl")
  assertEq(bl.x, 0, "bl x") ; assertEq(bl.y, 70, "bl y")
  local br = place.cornerPosition(s, img, "br")
  assertEq(br.x, 80, "br x") ; assertEq(br.y, 70, "br y")
  s:close()
end)

check("centerPosition centers the image", function()
  local s = Sprite(100, 80, ColorMode.RGB)
  local p = place.centerPosition(s, Image(20, 10, ColorMode.RGB))
  assertEq(p.x, 40, "x")
  assertEq(p.y, 35, "y")
  s:close()
end)

check("a snapped image lands fully inside the canvas", function()
  local s = Sprite(100, 80, ColorMode.RGB)
  local img = Image(20, 10, ColorMode.RGB)
  for _, corner in ipairs{ "tl", "tr", "bl", "br" } do
    local p = place.cornerPosition(s, img, corner)
    assertTrue(p.x >= 0 and p.y >= 0, corner .. " went negative")
    assertTrue(p.x + img.width <= s.width, corner .. " overran the width")
    assertTrue(p.y + img.height <= s.height, corner .. " overran the height")
  end
  local c = place.centerPosition(s, img)
  assertTrue(c.x >= 0 and c.x + img.width <= s.width, "center overran")
  s:close()
end)

check("an oversized image still gets a sane snap position", function()
  local s = Sprite(16, 16, ColorMode.RGB)
  local img = Image(64, 64, ColorMode.RGB)
  -- Bigger than the canvas, so it must hang off rather than throw.
  local br = place.cornerPosition(s, img, "br")
  assertEq(br.x, -48, "br x")
  local c = place.centerPosition(s, img)
  assertEq(c.x, -24, "center x")
  s:close()
end)

----------------------------------------------------------------------
section("placing onto a chosen layer")

check("put onto an existing layer keeps that layer's artwork", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local target = s.layers[1]
  s.cels[1].image:clear(rgba(255, 0, 0, 255))

  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 0, 255, 255))
  place.put(s, img, Point(10, 10), "x", target)

  assertEq(#s.layers, 1, "must not have added a layer")
  local cel = target:cel(1)
  assertEq(cel.image:getPixel(11 - cel.position.x, 11 - cel.position.y),
    rgba(0, 0, 255, 255), "new pixels missing")
  assertEq(cel.image:getPixel(0 - cel.position.x, 0 - cel.position.y),
    rgba(255, 0, 0, 255), "existing artwork was destroyed")
  s:close()
end)

check("put onto an existing layer grows the cel to fit", function()
  local s = Sprite(64, 64, ColorMode.RGB)
  local target = s.layers[1]
  local small = Image(4, 4, ColorMode.RGB)
  small:clear(rgba(255, 0, 0, 255))
  s:newCel(target, 1, small, Point(0, 0))

  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 0, 255, 255))
  place.put(s, img, Point(40, 40), "x", target)

  local cel = target:cel(1)
  assertTrue(cel.image.width >= 44, "cel did not grow, width " .. cel.image.width)
  assertEq(cel.image:getPixel(0 - cel.position.x, 0 - cel.position.y),
    rgba(255, 0, 0, 255), "original content lost")
  assertEq(cel.image:getPixel(41 - cel.position.x, 41 - cel.position.y),
    rgba(0, 0, 255, 255), "new content missing")
  s:close()
end)

check("put onto an empty layer just creates the cel", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local target = s:newLayer()
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 255, 0, 255))
  place.put(s, img, Point(5, 5), "x", target)

  local cel = target:cel(1)
  assertTrue(cel, "no cel created")
  assertEq(cel.position.x, 5, "x")
  s:close()
end)

check("put with no target layer still makes a new one", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local before = #s.layers
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 255, 0, 255))
  local layer = place.put(s, img, Point(1, 1), "Fresh", nil)
  assertEq(#s.layers, before + 1, "layer count")
  assertEq(layer.name, "Fresh", "name")
  s:close()
end)

----------------------------------------------------------------------
-- Spreading a batch over layers or frames.

local function batchItems(n, w, h)
  local items = {}
  for i = 1, n do
    local img = Image(w or 4, h or 4, ColorMode.RGB)
    img:clear(rgba(i * 20, 0, 0, 255))
    items[i] = { image = img, pos = Point(0, 0), name = "img " .. i }
  end
  return items
end

check("asLayers gives every image its own layer", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local before = #s.layers
  place.asLayers(s, batchItems(4))
  assertEq(#s.layers, before + 4, "layer count")
  assertEq(#s.frames, 1, "should not have added frames")
  s:close()
end)

check("asLayers names each layer and keeps the images distinct", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  place.asLayers(s, batchItems(3))

  local seen = {}
  for i = 1, #s.layers do
    local cel = s.layers[i]:cel(1)
    if cel then seen[cel.image:getPixel(0, 0)] = true end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  assertTrue(n >= 3, "layers ended up sharing an image, saw " .. n)
  s:close()
end)

check("asLayers is a single undo step", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local before = #s.layers
  place.asLayers(s, batchItems(4))
  app.undo()
  assertEq(#s.layers, before, "one undo should remove the whole batch")
  s:close()
end)

check("asFrames lays the batch along the timeline on one new layer", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local before = #s.layers
  local layer = place.asFrames(s, batchItems(5), nil, "Batch")

  assertEq(#s.layers, before + 1, "should add exactly one layer")
  assertEq(#s.frames, 5, "frame count")
  assertEq(layer.name, "Batch", "layer name")
  for f = 1, 5 do
    assertTrue(layer:cel(f), "no cel at frame " .. f)
  end
  s:close()
end)

check("asFrames puts a different image on each frame", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local layer = place.asFrames(s, batchItems(4), nil, "Batch")
  local seen = {}
  for f = 1, 4 do
    seen[layer:cel(f).image:getPixel(0, 0)] = true
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  assertEq(n, 4, "frames shared images")
  s:close()
end)

check("asFrames onto an existing layer keeps that layer's artwork", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local target = s.layers[1]
  s.cels[1].image:clear(rgba(0, 255, 0, 255))

  place.asFrames(s, batchItems(3), target, "Batch")
  assertEq(#s.layers, 1, "must not have added a layer")

  local cel = target:cel(1)
  -- Frame 1 had artwork; the import is 4x4 at 0,0 so the far corner survives.
  assertEq(cel.image:getPixel(31 - cel.position.x, 31 - cel.position.y),
    rgba(0, 255, 0, 255), "existing artwork was destroyed")
  s:close()
end)

check("asFrames never removes frames the artist already had", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  s:newEmptyFrame()
  s:newEmptyFrame()
  s:newEmptyFrame()
  assertEq(#s.frames, 4, "setup")
  app.frame = s.frames[1]

  place.asFrames(s, batchItems(2), nil, "Batch")
  assertEq(#s.frames, 4, "should not shrink the timeline")
  s:close()
end)

check("asFrames starts at the current frame, not the first", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  s:newEmptyFrame()
  s:newEmptyFrame()
  app.frame = s.frames[3]

  local layer = place.asFrames(s, batchItems(2), nil, "Batch")
  assertEq(#s.frames, 4, "should have extended to cover frames 3 and 4")
  assertEq(layer:cel(1), nil, "nothing should land before the current frame")
  assertTrue(layer:cel(3), "no cel at the current frame")
  assertTrue(layer:cel(4), "no cel at the frame after")
  s:close()
end)

check("asFrames grows the timeline when the batch is longer", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  place.asFrames(s, batchItems(7), nil, "Batch")
  assertEq(#s.frames, 7, "frame count")
  s:close()
end)

-- One image is now just a batch of one: "one per frame" is the only path a
-- single import takes, and it has to land on the selected keyframe without
-- adding frames or disturbing the layer.
check("asFrames with one image lands on the selected keyframe", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  s:newEmptyFrame()
  s:newEmptyFrame()
  local target = s.layers[1]
  app.frame = s.frames[2]

  place.asFrames(s, batchItems(1), target, "Solo")

  assertEq(#s.frames, 3, "should not have added a frame")
  assertEq(#s.layers, 1, "should not have added a layer")
  assertTrue(target:cel(2), "nothing landed on the selected frame")
  assertEq(target:cel(3), nil, "should not have touched the next frame")
  s:close()
end)

check("asFrames is a single undo step", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  place.asFrames(s, batchItems(5), nil, "Batch")
  app.undo()
  assertEq(#s.frames, 1, "one undo should remove the whole batch")
  s:close()
end)

check("merging onto an existing layer is a single undo step", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local target = s.layers[1]
  s.cels[1].image:clear(rgba(255, 0, 0, 255))

  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 0, 255, 255))
  place.put(s, img, Point(10, 10), "x", target)
  app.undo()

  local cel = target:cel(1)
  assertEq(cel.image:getPixel(11 - cel.position.x, 11 - cel.position.y),
    rgba(255, 0, 0, 255), "one undo should remove the whole placement")
  s:close()
end)

check("transparent pixels of the import do not punch holes", function()
  local s = Sprite(32, 32, ColorMode.RGB)
  local target = s.layers[1]
  s.cels[1].image:clear(rgba(255, 0, 0, 255))

  local img = Image(8, 8, ColorMode.RGB)      -- fully transparent
  img:putPixel(0, 0, rgba(0, 0, 255, 255))
  place.put(s, img, Point(4, 4), "x", target)

  local cel = target:cel(1)
  assertEq(cel.image:getPixel(6 - cel.position.x, 6 - cel.position.y),
    rgba(255, 0, 0, 255), "a transparent pixel erased what was underneath")
  s:close()
end)

----------------------------------------------------------------------
section("load and run")

check("load reads an RGB png back", function()
  local path = tmpFile("t_rgb.png")
  local s = makeSource(64, 48)
  s:saveAs(path)
  s:close()

  local src, err = convert.load(path)
  assertTrue(src, tostring(err))
  assertEq(src.width, 64, "width")
  assertEq(src.height, 48, "height")
  assertEq(src.image.colorMode, ColorMode.RGB, "color mode")
  assertEq(src.name, "t_rgb", "name")
  os.remove(path)
end)

check("load reads an indexed png through its palette", function()
  local path = tmpFile("t_indexed.png")
  local s = makeIndexedSprite(16, 16)
  s:saveAs(path)
  s:close()

  local src, err = convert.load(path)
  assertTrue(src, tostring(err))
  assertEq(src.image.colorMode, ColorMode.RGB, "normalized to RGB")

  -- The exact palette colors must survive, not just "more than one color".
  assertEq(src.scale, 1, "no grid should be detected in this fixture")
  local img = src.image
  assertEq(img:getPixel(8, 8),  rgba(255, 0, 0, 255), "index 1 -> red")
  assertEq(img:getPixel(8, 1),  rgba(0, 255, 0, 255), "index 2 -> green")
  assertEq(img:getPixel(8, 14), rgba(0, 0, 255, 255), "index 3 -> blue")
  assertEq(rgbaA(img:getPixel(1, 8)), 0, "index 0 -> transparent")
  os.remove(path)
end)

check("load reports a missing file instead of throwing", function()
  local src, err = convert.load(tmpFile("t_does_not_exist.png"))
  assertEq(src, nil, "should refuse")
  assertTrue(type(err) == "string" and #err > 0, "expected a message")
end)

check("load caps oversized sources but reports true dimensions", function()
  local path = tmpFile("t_big.png")
  local s = makeSource(2400, 1200)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  assertEq(src.width, 2400, "reported width")
  assertEq(src.height, 1200, "reported height")
  assertTrue(src.image.width <= 1024, "working copy not capped: " .. src.image.width)
  os.remove(path)
end)

check("scale 100 on a big file gives the ceiling, not the file's size", function()
  local path = tmpFile("t_run.png")
  local s = makeSource(2400, 1200)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  local out = convert.run(src, { scale = 100, colors = 16, alphaCut = 128 })
  assertEq(out.width, 256, "width")
  assertEq(out.height, 128, "height should follow the shape")
  assertTrue(uniqueColors(out) <= 16, "color ceiling ignored")
  os.remove(path)
end)

check("scale 100 on a small file keeps the original resolution", function()
  local path = tmpFile("t_one.png")
  local s = makeSource(64, 48)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  local out = convert.run(src, { scale = 100, colors = nil, alphaCut = 128 })
  assertEq(out.width, 64, "width")
  assertEq(out.height, 48, "height")
  os.remove(path)
end)

check("run without a color limit leaves more than the ceiling would", function()
  local path = tmpFile("t_nolimit.png")
  local s = makeSource(128, 96)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  local out = convert.run(src, { scale = 100, colors = nil, alphaCut = 1 })
  assertTrue(uniqueColors(out) > 64, "expected an unquantized spread, got " .. uniqueColors(out))
  os.remove(path)
end)

check("run clamps a runaway output and keeps the aspect ratio", function()
  local path = tmpFile("t_clamp.png")
  local s = makeSource(2400, 1200)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  local out = convert.run(src, { scale = 100, colors = nil, alphaCut = 1 })
  assertTrue(math.max(out.width, out.height) <= 256,
    "not clamped: " .. out.width .. "x" .. out.height)
  local ratio = out.width / out.height
  assertTrue(math.abs(ratio - 2.0) < 0.05, "aspect drifted to " .. ratio)
  os.remove(path)
end)

check("maxOutputLong never exceeds the ceiling", function()
  local s = Sprite(128, 96, ColorMode.RGB)
  local src = { image = s.cels[1].image, width = 4000, height = 3000, scale = 1 }
  -- The working copy is only 128 across, so that is the real limit.
  assertEq(convert.maxOutputLong(src), 128, "limited by the working copy")
  s:close()
end)

check("maxOutputLong will not invent detail from a small file", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  assertEq(convert.maxOutputLong(src), 64, "should not exceed the source")
  s:close()
end)

check("scale 1 gives a single pixel on the long side", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  local out = convert.run(src, { scale = 1, colors = nil })
  assertEq(math.max(out.width, out.height), 3, "1% of 256 rounds to 3")
  assertTrue(out.width >= 1 and out.height >= 1, "degenerate size")
  s:close()
end)

check("scale keeps the source's shape", function()
  local s = makeSource(256, 128)
  local src = { image = s.cels[1].image, width = 256, height = 128, scale = 1 }
  for _, v in ipairs{ 10, 25, 50, 75, 100 } do
    local out = convert.run(src, { scale = v, colors = nil })
    local ratio = out.width / out.height
    assertTrue(math.abs(ratio - 2.0) < 0.2,
      string.format("scale %d drifted to %.2f", v, ratio))
  end
  s:close()
end)

-- The bug this guards: the old pixel size slider had a dead run at one end,
-- where every position produced the same clamped picture. Scale is defined
-- against what the source can actually give, so it climbs the whole way.
check("scale climbs monotonically from 1 to 100", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 2048, height = 1536, scale = 1 }

  local last = 0
  for _, v in ipairs{ 1, 10, 25, 50, 75, 100 } do
    local out = convert.run(src, { scale = v, colors = nil })
    assertTrue(out.width >= last,
      string.format("scale %d gave %dpx, smaller than the step before", v, out.width))
    if v > 1 then
      assertTrue(out.width > last, string.format("scale %d did nothing", v))
    end
    last = out.width
  end
  assertEq(last, convert.maxOutputLong(src), "scale 100 should reach the maximum")
  s:close()
end)

-- Typing a size drags the slider along with it, so the two controls never
-- disagree about the same number.
check("scaleForSize is the inverse of sizeForScale", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }

  for _, v in ipairs{ 10, 25, 50, 75, 100 } do
    local w, h = convert.sizeForScale(src, v)
    local back = convert.scaleForSize(src, math.max(w, h))
    assertTrue(math.abs(back - v) <= 1,
      string.format("scale %d became %d after a round trip", v, back))
  end
  s:close()
end)

check("scaleForSize stays inside the slider range", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  assertTrue(convert.scaleForSize(src, 0) >= 1, "floor")
  assertTrue(convert.scaleForSize(src, 99999) <= 100, "ceiling")
  assertEq(convert.scaleForSize(src, convert.maxOutputLong(src)), 100, "max is 100")
  s:close()
end)

check("scale is clamped to 1..100 rather than trusted", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 256, height = 192, scale = 1 }
  local low  = convert.run(src, { scale = -50, colors = nil })
  local high = convert.run(src, { scale = 900, colors = nil })
  assertTrue(low.width >= 1, "negative scale")
  assertEq(high.width, 256, "over-large scale should stop at the maximum")
  s:close()
end)

check("run never produces a zero-sized image", function()
  local path = tmpFile("t_tiny.png")
  local s = makeSource(16, 16)
  s:saveAs(path)
  s:close()

  local src = convert.load(path)
  local out = convert.run(src, { scale = 100, colors = 8, alphaCut = 128 })
  assertTrue(out.width >= 1 and out.height >= 1, "degenerate size")
  os.remove(path)
end)

----------------------------------------------------------------------
section("native resolution detection")

check("detectScale finds the exact upscale factor", function()
  local art = makePixelArt(16, 16)
  for _, k in ipairs{ 2, 3, 4, 8, 16 } do
    local big = upscale(art.cels[1].image, k)
    assertEq(convert.detectScale(big), k, "factor " .. k)
  end
  art:close()
end)

check("detectScale returns the largest factor, not a divisor of it", function()
  local art = makePixelArt(8, 8)
  local big = upscale(art.cels[1].image, 16)   -- also trivially 2x, 4x and 8x
  assertEq(convert.detectScale(big), 16, "factor")
  art:close()
end)

check("detectScale leaves a photographic image alone", function()
  local s = makeSource(128, 96)
  assertEq(convert.detectScale(s.cels[1].image), 1, "should find no grid")
  s:close()
end)

check("detectScale leaves native pixel art alone", function()
  local art = makePixelArt(32, 32)
  assertEq(convert.detectScale(art.cels[1].image), 1, "already native")
  art:close()
end)

-- The true factor here is 8, but that would leave a 2x2 image. Detection is
-- expected to fall back to a smaller factor rather than reduce that far - and
-- a smaller factor is still perfectly lossless, which is what actually matters.
check("detectScale never reduces below a usable size, and stays lossless", function()
  local art = makePixelArt(2, 2)
  local big = upscale(art.cels[1].image, 8)    -- 16x16 from only 2x2 of art
  local k = convert.detectScale(big)

  assertTrue(big.width / k >= 4, "reduced to " .. (big.width / k) .. "px, too far")

  local back = upscale(convert.blockReduce(big, k), k)
  for y = 0, big.height - 1 do
    for x = 0, big.width - 1 do
      assertEq(back:getPixel(x, y), big:getPixel(x, y), "lossy at " .. x .. "," .. y)
    end
  end
  art:close()
end)

check("blockReduce recovers the source pixels exactly", function()
  local art = makePixelArt(16, 16)
  local original = art.cels[1].image:clone()
  local out = convert.blockReduce(upscale(original, 8), 8)
  assertEq(out.width, 16, "width")
  for y = 0, 15 do
    for x = 0, 15 do
      assertEq(out:getPixel(x, y), original:getPixel(x, y), "pixel " .. x .. "," .. y)
    end
  end
  art:close()
end)

-- Detected pixel art has a right answer, not a taste-based one: its own native
-- resolution, which the working copy already holds. That is scale 100.
check("suggest goes to full scale for detected pixel art", function()
  assertEq(convert.suggest({ width = 512, height = 512, scale = 16 }), 100, "native")
end)

check("suggest aims at a workable size for a photo", function()
  local s = makeSource(256, 192)
  local src = { image = s.cels[1].image, width = 4000, height = 3000, scale = 1 }
  -- maxOutputLong is 256 here, and the target is around 128, so about half.
  assertEq(convert.suggest(src), 50, "4000px photo")
  s:close()
end)

check("suggest leaves an already-small image at full scale", function()
  local s = makeSource(64, 48)
  local src = { image = s.cels[1].image, width = 64, height = 48, scale = 1 }
  assertEq(convert.suggest(src), 100, "64px is already under the target")
  s:close()
end)

check("suggest stays inside the slider range", function()
  assertTrue(convert.suggest({ width = 40000, height = 40000, scale = 1 }) >= 1, "floor")
  assertTrue(convert.suggest({ width = 4, height = 4, scale = 1 }) <= 100, "ceiling")
end)

check("upscaled pixel art round-trips back to the original pixels", function()
  local path = tmpFile("t_upscaled.png")
  local art = makePixelArt(16, 16)
  local original = art.cels[1].image:clone()

  local big = upscale(original, 16)                  -- 256x256 on disk
  local carrier = Sprite(big.width, big.height, ColorMode.RGB)
  carrier.cels[1].image:drawImage(big, Point(0, 0))
  carrier:saveAs(path)
  carrier:close()
  art:close()

  local src, err = convert.load(path)
  assertTrue(src, tostring(err))
  assertEq(src.scale, 16, "detected scale")
  assertEq(src.width, 256, "reported width is still the file's own")

  assertEq(convert.suggest(src), 100, "detected art should start at full scale")

  -- Every filter must survive this. Once the grid has been collapsed the
  -- resample is 1:1, where each filter's weights degenerate to "take this
  -- pixel" - so a method that corrupts the round trip is a broken filter.
  for _, m in ipairs(ALL_METHODS) do
    local out = convert.run(src, { scale = 100, colors = nil, alphaCut = 1, method = m })
    assertEq(out.width, 16, m .. " output width")
    assertEq(out.height, 16, m .. " output height")
    for y = 0, 15 do
      for x = 0, 15 do
        assertEq(out:getPixel(x, y), original:getPixel(x, y), m .. " at " .. x .. "," .. y)
      end
    end
  end
  os.remove(path)
end)

----------------------------------------------------------------------
section("importing from an open sprite")

-- This is the route the Import button takes: Aseprite's Open dialog hands back
-- a sprite, never a path. The dialog cannot run headlessly, but everything it
-- does to the sprite afterwards can.

check("fromSprite takes an open sprite as the source", function()
  local s = makeSource(64, 48)
  local src = convert.fromSprite(s)
  assertEq(src.width, 64, "width")
  assertEq(src.height, 48, "height")
  assertEq(src.image.colorMode, ColorMode.RGB, "color mode")
  s:close()
end)

check("fromSprite detects native resolution too", function()
  local art = makePixelArt(16, 16)
  local big = upscale(art.cels[1].image, 8)
  local carrier = Sprite(big.width, big.height, ColorMode.RGB)
  carrier.cels[1].image:drawImage(big, Point(0, 0))

  local src = convert.fromSprite(carrier)
  assertEq(src.scale, 8, "scale")
  assertEq(src.image.width, 16, "reduced to native width")
  carrier:close()
  art:close()
end)

check("fromSprite flattens an indexed sprite through its palette", function()
  local s = makeIndexedSprite(16, 16)
  local src = convert.fromSprite(s)
  assertEq(src.image.colorMode, ColorMode.RGB, "normalized to RGB")
  assertEq(src.image:getPixel(8, 8), rgba(255, 0, 0, 255), "index 1 -> red")
  assertEq(rgbaA(src.image:getPixel(1, 8)), 0, "index 0 -> transparent")
  s:close()
end)

check("fromSprite composites every visible layer, not just the active one", function()
  local s = Sprite(16, 16, ColorMode.RGB)
  s.cels[1].image:clear(rgba(255, 0, 0, 255))
  local top = s:newLayer()
  -- Odd size at an odd offset, so this fixture is not itself a clean grid and
  -- native resolution detection stays out of a test about compositing.
  local patch = Image(5, 5, ColorMode.RGB)
  patch:clear(rgba(0, 0, 255, 255))
  s:newCel(top, 1, patch, Point(3, 3))

  local src = convert.fromSprite(s)
  assertEq(src.scale, 1, "no grid should be detected in this fixture")
  assertEq(src.image:getPixel(5, 5),   rgba(0, 0, 255, 255), "upper layer")
  assertEq(src.image:getPixel(12, 12), rgba(255, 0, 0, 255), "lower layer")
  s:close()
end)

-- A file opened next to 7.png, 8.png, 9.png can arrive as one sprite holding
-- three frames. Importing per frame is what makes that harmless - and is the
-- same mechanism that imports a gif, or a multi-file selection.
check("fromSprite imports each frame separately", function()
  local s = Sprite(16, 16, ColorMode.RGB)
  s.cels[1].image:clear(rgba(255, 0, 0, 255))
  for i = 2, 3 do
    s:newEmptyFrame()
    local img = Image(16, 16, ColorMode.RGB)
    img:clear(rgba(0, i * 80, 0, 255))
    s:newCel(s.layers[1], i, img, Point(0, 0))
  end
  assertEq(#s.frames, 3, "setup")

  local first  = convert.fromSprite(s, 1)
  local second = convert.fromSprite(s, 2)
  local third  = convert.fromSprite(s, 3)

  assertEq(first.image:getPixel(8, 8),  rgba(255, 0, 0, 255), "frame 1")
  assertEq(second.image:getPixel(8, 8), rgba(0, 160, 0, 255), "frame 2")
  assertEq(third.image:getPixel(8, 8),  rgba(0, 240, 0, 255), "frame 3")
  s:close()
end)

check("fromSprite defaults to the first frame", function()
  local s = Sprite(16, 16, ColorMode.RGB)
  s.cels[1].image:clear(rgba(255, 0, 0, 255))
  s:newEmptyFrame()

  local a = convert.fromSprite(s)
  local b = convert.fromSprite(s, 1)
  assertEq(a.image:getPixel(8, 8), b.image:getPixel(8, 8), "default frame")
  s:close()
end)

check("frames of one sprite record which frame they came from", function()
  local s = Sprite(16, 16, ColorMode.RGB)
  s.cels[1].image:clear(rgba(255, 0, 0, 255))
  s:newEmptyFrame()

  local a = convert.fromSprite(s, 1)
  local b = convert.fromSprite(s, 2)
  assertEq(a.frame, 1, "frame 1")
  assertEq(b.frame, 2, "frame 2")
  -- The name stays clean: the dropdown numbers its own entries.
  assertEq(a.name, b.name, "names should not carry the frame")
  s:close()
end)

check("a single-frame sprite records no frame", function()
  local s = makeSource(16, 16)
  assertEq(convert.fromSprite(s, 1).frame, nil, "frame should be unset")
  s:close()
end)

check("a single-frame sprite keeps its plain name", function()
  local path = tmpFile("t_single.png")
  local s = makeSource(32, 32)
  s:saveAs(path)
  local src = convert.fromSprite(s, 1)
  assertEq(src.name, "t_single", "name should not be suffixed")
  s:close()
  os.remove(path)
end)

check("fromSprite names the source from its filename", function()
  local path = tmpFile("t_named.png")
  local s = makeSource(32, 32)
  s:saveAs(path)
  local src = convert.fromSprite(s)
  assertEq(src.name, "t_named", "name")
  s:close()
  os.remove(path)
end)

check("fromSprite copes with an unsaved sprite", function()
  local s = makeSource(32, 32)
  local src = convert.fromSprite(s)
  assertTrue(type(src.name) == "string" and #src.name > 0, "expected some name")
  s:close()
end)

check("sprites must be matched by id, not by table key", function()
  -- Guards the assumption importViaOpenDialog rests on. If this ever starts
  -- passing for table keys, the id indirection can go.
  local s = Sprite(4, 4, ColorMode.RGB)

  -- app.sprites is not ordered newest-last, so find it by identity. The `==`
  -- operator does work on sprites; it is only table keys that do not.
  local at
  for i = 1, #app.sprites do
    if app.sprites[i] == s then at = i end
  end
  assertTrue(at, "sprite not found in app.sprites")

  local byKey = {}
  byKey[app.sprites[at]] = true
  assertEq(byKey[app.sprites[at]], nil,
    "table keys now work - re-check importViaOpenDialog")

  local byId = {}
  byId[app.sprites[at].id] = true
  assertTrue(byId[s.id], "id lookup must work")
  s:close()
end)

----------------------------------------------------------------------
section("color mode matching")

check("forSprite passes RGB through as a copy", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(1, 2, 3, 255))
  local out = convert.forSprite(img, s)
  assertEq(out.colorMode, ColorMode.RGB, "color mode")
  out:putPixel(0, 0, rgba(9, 9, 9, 255))
  assertEq(img:getPixel(0, 0), rgba(1, 2, 3, 255), "source aliased into the copy")
  s:close()
end)

check("forSprite converts to grayscale", function()
  local s = Sprite(8, 8, ColorMode.RGB)
  app.command.ChangePixelFormat{ format = "gray" }
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(255, 255, 255, 255))
  local out = convert.forSprite(img, s)
  assertEq(out.colorMode, ColorMode.GRAY, "color mode")
  assertEq(app.pixelColor.grayaV(out:getPixel(0, 0)), 255, "white stays white")
  s:close()
end)

check("forSprite maps onto an indexed sprite's palette", function()
  local s = makeIndexedSprite()

  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(250, 5, 5, 255))       -- very nearly the palette's red
  local out = convert.forSprite(img, s)
  assertEq(out.colorMode, ColorMode.INDEXED, "color mode")
  assertEq(out:getPixel(0, 0), 1, "should map to the red index")
  s:close()
end)

check("forSprite picks the nearest entry, not the first", function()
  local s = makeIndexedSprite()
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(20, 20, 230, 255))     -- nearly the palette's blue
  local out = convert.forSprite(img, s)
  assertEq(out:getPixel(0, 0), 3, "should map to the blue index")
  s:close()
end)

check("forSprite never maps onto the transparent index", function()
  local s = makeIndexedSprite()
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(0, 0, 0, 255))         -- black: the transparent entry is also black
  local out = convert.forSprite(img, s)
  assertTrue(out:getPixel(0, 0) ~= 0, "opaque black landed on the transparent index")
  s:close()
end)

check("forSprite keeps transparency on an indexed sprite", function()
  local s = makeIndexedSprite()
  local img = Image(4, 4, ColorMode.RGB)   -- entirely transparent
  local out = convert.forSprite(img, s)
  assertEq(out:getPixel(0, 0), s.transparentColor, "should be the transparent index")
  s:close()
end)

----------------------------------------------------------------------
section("placing")

check("centeredOn puts the image's middle on the point", function()
  local img = Image(10, 8, ColorMode.RGB)
  local p = place.centeredOn(img, Point(32, 32))
  assertEq(p.x, 27, "x = 32 - 10/2")
  assertEq(p.y, 28, "y = 32 - 8/2")
end)

check("centeredOn tolerates a point near the canvas edge", function()
  local img = Image(10, 8, ColorMode.RGB)
  assertEq(place.centeredOn(img, Point(0, 0)).x, -5, "negative x is fine")
end)

check("put is a single undo step", function()
  local s = Sprite(64, 64, ColorMode.RGB)
  local img = Image(4, 4, ColorMode.RGB)
  img:clear(rgba(255, 0, 255, 255))
  place.put(s, img, Point(32, 32), "Undoable")
  assertEq(#s.layers, 2, "setup")
  app.undo()
  assertEq(#s.layers, 1, "one undo should remove the whole placement")
  s:close()
end)

check("pickPoint reports failure when there is no editor", function()
  -- Batch mode has no editor, so this must fall back rather than throw.
  assertEq(place.pickPoint("x", function() end), false, "expected false in batch mode")
end)

check("newSprite sizes the sprite to the image", function()
  local img = Image(20, 12, ColorMode.RGB)
  img:clear(rgba(0, 255, 0, 255))
  local s = place.newSprite(img, "fresh")
  assertEq(s.width, 20, "width")
  assertEq(s.height, 12, "height")
  assertEq(s.cels[1].image:getPixel(0, 0), rgba(0, 255, 0, 255), "content")
  s:close()
end)

----------------------------------------------------------------------
section("modules")

-- The dialog itself cannot run headlessly, but loading it catches syntax
-- errors and bad top-level references that would otherwise only surface when
-- the artist clicks the menu entry.
check("ui module loads and exposes open()", function()
  local ui = dofile(SRC .. "/ui.lua")
  assertTrue(type(ui) == "table", "ui did not return a table")
  assertTrue(type(ui.open) == "function", "ui.open is not a function")
end)

----------------------------------------------------------------------
local header = string.format("PixelImport tests: %d passed, %d failed", passed, failed)
local f = io.open(ROOT .. "/run.results.txt", "w")
if f then
  f:write(header .. "\n" .. table.concat(log, "\n") .. "\n")
  f:close()
end
