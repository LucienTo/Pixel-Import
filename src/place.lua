-- Dropping a converted image into a sprite.

local place = {}

local floor = math.floor

local function currentFrame()
  return app.frame and app.frame.frameNumber or 1
end

-- What "nothing here" means for an image. Indexed sprites carry their
-- transparent index on the sprite, not the image.
local function emptyValue(sprite, img)
  if img.colorMode == ColorMode.INDEXED then
    return sprite and sprite.transparentColor or 0
  end
  return 0
end

local function isEmpty(p, colorMode, empty)
  if colorMode == ColorMode.RGB then return app.pixelColor.rgbaA(p) == 0 end
  if colorMode == ColorMode.GRAY then return app.pixelColor.grayaA(p) == 0 end
  return p == empty
end

-- Imported images are binary alpha by construction - every pixel is fully
-- opaque or fully gone - so "skip the empty ones, overwrite the rest" is the
-- whole compositing rule, and it behaves identically in RGB, grayscale and
-- indexed without a special case for any of them.
local function blit(dst, src, dx, dy, empty)
  local mode = src.colorMode
  for y = 0, src.height - 1 do
    for x = 0, src.width - 1 do
      local p = src:getPixel(x, y)
      if not isEmpty(p, mode, empty) then
        dst:putPixel(x + dx, y + dy, p)
      end
    end
  end
end

-- Add the image to a layer that already has artwork on it, growing the cel to
-- cover both. Replacing the cel outright would silently delete whatever the
-- artist had already drawn there.
local function mergeIntoCel(sprite, layer, img, pos, frame)
  frame = frame or currentFrame()
  local cel = layer:cel(frame)
  if not cel then
    sprite:newCel(layer, frame, img, pos)
    return
  end

  local empty = emptyValue(sprite, cel.image)
  local x0 = math.min(cel.position.x, pos.x)
  local y0 = math.min(cel.position.y, pos.y)
  local x1 = math.max(cel.position.x + cel.image.width,  pos.x + img.width)
  local y1 = math.max(cel.position.y + cel.image.height, pos.y + img.height)

  local merged = Image(x1 - x0, y1 - y0, cel.image.colorMode)
  merged:clear(empty)
  blit(merged, cel.image, cel.position.x - x0, cel.position.y - y0, empty)
  blit(merged, img,       pos.x - x0,          pos.y - y0,          empty)

  sprite:newCel(layer, frame, merged, Point(x0, y0))
end

-- Write the image with its top-left at `pos`.
--
-- With no target layer this makes a new one, because an import is raw material
-- and the artist needs it separable from what they have already drawn - to
-- align it, dial its opacity down and trace over it, or throw it away.
function place.put(sprite, img, pos, name, targetLayer)
  local layer = targetLayer

  app.transaction("Place Imported Image", function()
    if layer then
      mergeIntoCel(sprite, layer, img, pos)
    else
      layer = sprite:newLayer()
      layer.name = name or "Imported"
      sprite:newCel(layer, currentFrame(), img, pos)
    end
  end)

  app.layer = layer
  app.refresh()
  return layer
end

-- The top-left that puts the image's center on `pt`, for placing at a clicked
-- point rather than at a canvas anchor.
function place.centeredOn(img, pt)
  return Point(pt.x - floor(img.width / 2), pt.y - floor(img.height / 2))
end

-- Grow the sprite until it has at least `count` frames. Never shrinks: frames
-- the artist made are not ours to remove.
local function ensureFrames(sprite, count)
  while #sprite.frames < count do
    sprite:newEmptyFrame()
  end
end

-- A batch of images, each on a new layer of its own, all at the current frame.
-- `items` is an array of { image, pos, name }.
function place.asLayers(sprite, items)
  local first
  app.transaction("Place Imported Images", function()
    for _, item in ipairs(items) do
      local layer = sprite:newLayer()
      layer.name = item.name
      sprite:newCel(layer, currentFrame(), item.image, item.pos)
      first = first or layer
    end
  end)
  if first then app.layer = first end
  app.refresh()
  return first
end

-- A batch of images laid along the timeline instead, one per frame, starting
-- at the current frame. With no target layer they get a new one, which is the
-- case where the import becomes an animation in its own right.
function place.asFrames(sprite, items, targetLayer, name)
  local start = currentFrame()
  local layer = targetLayer

  app.transaction("Place Imported Images", function()
    ensureFrames(sprite, start + #items - 1)

    if not layer then
      layer = sprite:newLayer()
      layer.name = name or "Imported"
    end

    for i, item in ipairs(items) do
      local frame = start + i - 1
      if targetLayer then
        mergeIntoCel(sprite, layer, item.image, item.pos, frame)
      else
        sprite:newCel(layer, frame, item.image, item.pos)
      end
    end
  end)

  app.layer = layer
  app.refresh()
  return layer
end

-- Flush against one of the canvas corners.
function place.cornerPosition(sprite, img, corner)
  local right  = (corner == "tr" or corner == "br")
  local bottom = (corner == "bl" or corner == "br")
  return Point(right and (sprite.width - img.width) or 0,
               bottom and (sprite.height - img.height) or 0)
end

-- Centered on the canvas, which is where a fitted image belongs: fitting
-- preserves aspect ratio, so one axis is usually short of the edge.
function place.centerPosition(sprite, img)
  return Point(floor((sprite.width - img.width) / 2),
               floor((sprite.height - img.height) / 2))
end

-- Hand off to Aseprite's own crosshair so placement reads like every other
-- click-to-place interaction in the app. Returns false if this build has no
-- such API, leaving the caller to fall back to an anchor.
--
-- It reports a point rather than placing anything, because one click has to be
-- able to anchor a whole batch.
function place.pickPoint(title, onPoint)
  local editor = app.editor
  if not (editor and editor.askPoint) then return false end

  editor:askPoint{
    title = title,
    onclick = function(ev)
      local pt = ev.point or ev.position
      if pt then onPoint(pt) end
    end,
  }
  return true
end

-- Used when there is nothing open to place into.
function place.newSprite(img, name)
  local spr = Sprite(img.width, img.height, ColorMode.RGB)
  spr.filename = (name or "imported") .. ".aseprite"
  spr.cels[1].image:drawImage(img, Point(0, 0))
  spr.layers[1].name = name or "Imported"
  app.refresh()
  return spr
end

return place
