-- Pixel Import dialog.

local ROOT = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local convert = dofile(ROOT .. "/convert.lua")
local place   = dofile(ROOT .. "/place.lua")

local ui = {}

-- The preview is the widest widget in the window on purpose. Aseprite lays
-- widgets out left-aligned with no way to center one, so if anything else were
-- wider the canvas would sit in a corner with dead space beside it.
local PREVIEW_W = 300
local PREVIEW_H = 240
local CHECKER = 8

-- gen::SequenceDecision: 0 ask, 1 yes, 2 no. Set only for the duration of the
-- Open dialog and put back afterwards, because it is the artist's global
-- preference and not ours to keep.
local SEQUENCE_NO = 2

local floor = math.floor

-- Corners live in the same list as everything else: they are placements, not a
-- separate axis, and splitting them out left a corner selector sitting there
-- doing nothing for every other mode.
local MODES = {
  { id = "center", label = "Snap to center" },
  { id = "tl",     label = "Snap to top left" },
  { id = "tr",     label = "Snap to top right" },
  { id = "bl",     label = "Snap to bottom left" },
  { id = "br",     label = "Snap to bottom right" },
  { id = "cursor", label = "Place with cursor" },
}

local PALETTES = {
  { id = "adaptive", label = "Adaptive (from image)" },
  { id = "sprite",   label = "Current sprite palette" },
}

-- What an import turns into. Frames first, and the default: a batch of images
-- is nearly always an animation, and with a single image it means "put it on
-- the selected keyframe", which is what the button says anyway.
local DISTRIBUTE = {
  { id = "frames", label = "All images, one per frame (animation)" },
  { id = "layers", label = "All images, one per layer (creates new layers)" },
}

local function labelsOf(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.label end
  return out
end

local function idOf(list, label, fallback)
  for _, e in ipairs(list) do
    if e.label == label then return e.id end
  end
  return fallback
end

-- Use `wanted` only if it is still one of the offered options. Menu contents
-- change between sessions; a remembered label that no longer exists would
-- leave the combobox showing something the artist cannot act on.
local function pick(labels, wanted, fallback)
  for _, l in ipairs(labels) do
    if l == wanted then return wanted end
  end
  return fallback
end

local function imageLabels(sources)
  if #sources == 0 then return { "-" } end
  local out = {}
  for i, s in ipairs(sources) do
    out[i] = string.format("%d. %s", i, s.name)
  end
  return out
end

local function indexFromLabel(label)
  return tonumber(label and label:match("^(%d+)%.")) or 1
end

-- A layer has no number beside it to lean on, so the frame goes in the name.
local function layerNameFor(src)
  if not src then return "Imported" end
  if src.frame then return string.format("%s %d", src.name, src.frame) end
  return src.name
end

-- Settings and the imported images outlive the window, because Place closes it
-- and the next thing an artist usually wants is another image, or the same one
-- somewhere else. Module level, so it lasts as long as the extension is loaded
-- rather than as long as the dialog is.
local remembered = {
  sources   = nil,
  selected  = 1,
  pixelSize = 8,
  colors    = 16,
  limit     = true,
}

function ui.open()
  -- All dialog state lives in this closure, so opening a second copy of the
  -- window gives a genuinely independent one.
  local sources  = remembered.sources or {}
  local selected = remembered.selected or 1
  local source   -- the entry of `sources` currently being shown
  local result   -- converted RGBA Image, or nil
  local preview  -- `result` resampled to the fixed preview box
  local boxW, boxH        -- that box, in screen pixels
  local explicitW, explicitH   -- a target size typed in, or nil for pixel size
  local closed  = false
  local syncing = false   -- guards the target fields against their own updates
  local dlg

  -- There is no status line any more, so anything worth saying is worth
  -- interrupting for. Everything that was merely chatty is gone - the source
  -- and target readouts under the preview say it better than prose did.
  local function complain(text)
    if closed then return end
    app.alert{ title = "Pixel Import", text = text }
  end

  local function closeDialog()
    closed = true
    pcall(function() dlg:close() end)
  end

  -- Modifying a widget makes Aseprite lay the dialog out again, which throws
  -- away a size the artist set by dragging the window edge - the window snaps
  -- back the moment anything is touched. Saving the bounds and putting them
  -- back keeps their size across a conversion.
  -- Re-entrant: handlers call recompute, which preserves too, and only the
  -- outermost may save - an inner one would capture bounds the outer call has
  -- already disturbed and lock the snapped-back size in.
  local boundsDepth = 0
  local function preserveBounds(fn)
    local saved
    if boundsDepth == 0 then
      local ok, b = pcall(function() return dlg.bounds end)
      if ok then saved = b end
    end

    boundsDepth = boundsDepth + 1
    local ok, err = pcall(fn)
    boundsDepth = boundsDepth - 1

    if boundsDepth == 0 and saved then
      pcall(function() dlg.bounds = saved end)
    end
    if not ok then error(err, 0) end
  end

  local function remember()
    if closed then return end
    local d = dlg.data
    remembered.sources    = sources
    remembered.selected   = selected
    remembered.scale      = d.scale
    remembered.colors     = d.colors
    remembered.limit      = d.limit
    remembered.method     = d.method
    remembered.palette    = d.palette
    remembered.placement  = d.placement
    remembered.distribute = d.distribute
  end

  -- Fixed once per selected image, from the shape being fed in.
  --
  -- Sizing the preview to the converted image instead would make it grow,
  -- shrink and re-center on every drag of the scale slider, which is precisely
  -- when the artist is trying to compare one setting against the last. The
  -- picture stays put; only its chunkiness changes.
  local function lockPreviewBox()
    local s = math.min(PREVIEW_W / source.width, PREVIEW_H / source.height)
    boxW = math.max(1, floor(source.width * s))
    boxH = math.max(1, floor(source.height * s))
  end

  -- Nearest-neighbor, done by hand. Handing the small image to the canvas and
  -- letting it scale would smooth the result, which is exactly the thing the
  -- artist opened this window to judge.
  local function buildPreview()
    if not result or not boxW then
      preview = nil
      return
    end

    preview = Image(boxW, boxH, ColorMode.RGB)
    local sx = result.width / boxW
    local sy = result.height / boxH

    for y = 0, boxH - 1 do
      local ry = math.min(result.height - 1, floor(y * sy))
      for x = 0, boxW - 1 do
        preview:putPixel(x, y, result:getPixel(math.min(result.width - 1, floor(x * sx)), ry))
      end
    end
  end

  -- Resolved live rather than cached, so editing the sprite's palette and
  -- reconverting picks up the change without a round trip through the menu.
  local function borrowedPalette()
    if idOf(PALETTES, dlg.data.palette, "adaptive") ~= "sprite" then return nil end
    local spr = app.sprite
    if not spr then return nil end
    local pal = convert.paletteFromSprite(spr)
    if #pal == 0 then return nil end
    return pal
  end

  -- One place that decides what the conversion is asked for.
  --
  -- A color count and a borrowed palette are passed together on purpose: the
  -- palette says which colors are allowed, the count says how many to spend.
  local function convertOpts()
    local d = dlg.data
    return {
      scale   = d.scale,
      targetW = explicitW,
      targetH = explicitH,
      palette = borrowedPalette(),
      colors  = d.limit and d.colors or nil,
      method  = convert.methodByLabel(d.method),
    }
  end

  -- `editing` is the field the artist is typing in, if any. Writing back to it
  -- mid-keystroke would fight them for the caret.
  local function recompute(editing)
    if not source then return end

    result = convert.run(source, convertOpts())
    remember()
    buildPreview()

    preserveBounds(function()
      -- The fields otherwise always show what actually happened, not what was
      -- asked for: a typed size can still be clamped by how much source there
      -- is.
      syncing = true
      dlg:modify{ id = "srcSize", text = string.format("%d x %d", source.width, source.height) }
      if editing ~= "targetW" then dlg:modify{ id = "targetW", text = tostring(result.width) } end
      if editing ~= "targetH" then dlg:modify{ id = "targetH", text = tostring(result.height) } end

      -- A size typed by hand drags the slider along with it, so the two
      -- controls never disagree about the same number. Only when a size was
      -- typed: otherwise this would fight the artist's own drag.
      if explicitW then
        dlg:modify{ id = "scale",
                    value = convert.scaleForSize(source, math.max(result.width, result.height)) }
      end
      syncing = false

      dlg:repaint()
    end)
  end

  local function paint(ev)
    local ctx  = ev.context
    local w, h = ctx.width, ctx.height

    -- Checkerboard, so pixels dropped by the alpha cut are obvious rather than
    -- blending into a flat backdrop.
    local dark  = Color{ r = 40, g = 40, b = 40 }
    local light = Color{ r = 56, g = 56, b = 56 }
    for y = 0, h - 1, CHECKER do
      for x = 0, w - 1, CHECKER do
        local even = (floor(x / CHECKER) + floor(y / CHECKER)) % 2 == 0
        ctx.color = even and dark or light
        ctx:fillRect(Rectangle(x, y, CHECKER, CHECKER))
      end
    end

    if preview then
      ctx:drawImage(preview, floor((w - preview.width) / 2), floor((h - preview.height) / 2))
    else
      local msg = "No image imported"
      ctx.color = Color{ r = 150, g = 150, b = 150 }
      local ok, size = pcall(function() return ctx:measureText(msg) end)
      local tx = ok and size and floor((w - size.width) / 2) or 8
      local ty = ok and size and floor((h - size.height) / 2) or floor(h / 2)
      ctx:fillText(msg, tx, ty)
    end
  end

  -- Typing a size takes over from the slider until the slider is touched
  -- again. Two controls over one number, and whichever was used last wins.
  --
  -- The width and height are locked to the source's shape: type one and the
  -- other follows. `which` says which field was actually touched, so the other
  -- is the one recalculated.
  local function onTargetEdited(which)
    if syncing or not source then return end

    local raw = which == "h" and dlg.data.targetH or dlg.data.targetW
    local typed = tonumber(raw)

    -- Mid-edit the box is legitimately empty - backspacing to retype should
    -- not have a 1 shoved into it. Leave it alone; touching any other control
    -- runs a conversion, which fills the field back in with the real value.
    if not typed or typed < 1 then return end

    local w = math.max(1, floor(typed))
    local h = math.max(1, floor(w * source.height / source.width + 0.5))
    if which == "h" then
      h = math.max(1, floor(typed))
      w = math.max(1, floor(h * source.width / source.height + 0.5))
    end

    explicitW, explicitH = w, h
    recompute(which == "h" and "targetH" or "targetW")
  end

  -- Guarded, because recompute writes the slider back when a size was typed:
  -- without this, that write would clear the very size it is reporting.
  local function onScaleChanged()
    if syncing then return end
    explicitW, explicitH = nil, nil
    recompute()
  end

  -- Show one of the imported images. Settings are shared across them, so the
  -- scale carries over; only a typed size is dropped, because it was a size
  -- for a different picture.
  local function selectImage(index)
    if #sources == 0 then
      source, result, preview = nil, nil, nil
      return
    end

    selected = math.max(1, math.min(#sources, index))
    source = sources[selected]
    explicitW, explicitH = nil, nil
    lockPreviewBox()
    preserveBounds(recompute)
  end

  local function onImageChanged()
    selectImage(indexFromLabel(dlg.data.image))
  end

  -- The scripting API has no bare file-chooser call, so this borrows Aseprite's
  -- own Open dialog. It hands back sprites rather than paths, so the job is to
  -- take the pixels and then put the workspace back exactly as we found it.
  --
  -- Sprites are matched by id, not by table key: re-indexing app.sprites hands
  -- out a fresh wrapper each time, so `seen[sprite]` silently never matches.
  local function importViaOpenDialog()
    local previous = app.sprite
    local before = {}
    for i = 1, #app.sprites do before[app.sprites[i].id] = true end

    -- Opening 7.png next to 8.png and 9.png otherwise raises "load the
    -- sequence?" every time. Suppressed for this one call and restored after,
    -- so a global preference the artist set stays theirs.
    local prefs, savedSequence = app.preferences and app.preferences.open_file, nil
    if prefs then
      pcall(function()
        savedSequence = prefs.open_sequence
        prefs.open_sequence = SEQUENCE_NO
      end)
    end

    app.command.OpenFile()

    if savedSequence ~= nil then
      pcall(function() prefs.open_sequence = savedSequence end)
    end

    local opened = {}
    for i = 1, #app.sprites do
      local s = app.sprites[i]
      if not before[s.id] then opened[#opened + 1] = s end
    end

    -- Nothing new, but the active tab changed: the artist picked a file that
    -- was already open, and OpenFile just switched to it. That is still a
    -- choice - but it is their tab, so we must not close it.
    local picked = opened
    if #picked == 0 then
      if app.sprite and (not previous or app.sprite ~= previous) then
        picked = { app.sprite }
      else
        return {}, 0                       -- canceled
      end
    end

    local imported, failed = {}, 0
    for _, spr in ipairs(picked) do
      -- Every frame is its own image. Whether the artist multi-selected three
      -- files, opened a gif, or a sequence loaded anyway, the result is the
      -- same list of pictures.
      for f = 1, #spr.frames do
        local ok, loaded = pcall(convert.fromSprite, spr, f)
        if ok then imported[#imported + 1] = loaded else failed = failed + 1 end
      end
    end

    for _, spr in ipairs(opened) do spr:close() end
    if previous then pcall(function() app.sprite = previous end) end

    return imported, failed
  end

  local function doImport()
    local imported, failed = importViaOpenDialog()
    if #imported == 0 then
      if failed > 0 then complain("Could not read that file.") end
      return                                -- silent on cancel
    end

    sources  = imported
    selected = 1
    source   = sources[1]
    explicitW, explicitH = nil, nil
    lockPreviewBox()

    preserveBounds(function()
      local labels = imageLabels(sources)
      pcall(function()
        dlg:modify{ id = "image", options = labels, option = labels[1] }
      end)

      dlg:modify{ id = "place", enabled = true }
      -- With one image there is nothing to distribute, so the choice is dead.
      dlg:modify{ id = "distribute", enabled = #sources > 1 }

      -- Start the artist at the right answer rather than at an arbitrary
      -- default. They can still drag it anywhere.
      syncing = true
      dlg:modify{ id = "scale", value = convert.suggest(source) }
      syncing = false

      recompute()
    end)
  end

  local function anchoredPosition(spr, img, mode)
    if mode == "center" or mode == "cursor" then
      return place.centerPosition(spr, img)
    end
    return place.cornerPosition(spr, img, mode)
  end

  -- Convert every imported image with the current settings. Only reached on an
  -- explicit click, so it can afford to be the slow path.
  local function convertAll(spr)
    local items = {}
    for i, src in ipairs(sources) do
      items[i] = {
        image = convert.forSprite(convert.run(src, convertOpts()), spr),
        name  = layerNameFor(src),
      }
    end
    return items
  end

  local function doPlace()
    if not result then
      complain("Import an image first.")
      return
    end

    local spr = app.sprite
    if not spr then
      local answer = app.alert{
        title = "Pixel Import",
        text = { "No sprite is open.", "Create a new one from this image?" },
        buttons = { "Create", "Cancel" },
      }
      if answer == 1 then
        place.newSprite(result:clone(), source and source.name)
        closeDialog()
      end
      return
    end

    remember()

    local mode   = idOf(MODES, dlg.data.placement, "center")
    local spread = idOf(DISTRIBUTE, dlg.data.distribute, "frames")

    -- The selected keyframe is the destination: whatever layer and frame the
    -- artist has active in the timeline.
    local target = app.layer

    -- One image is just a batch of one, so there is a single path through
    -- here. "One per frame" with one image means the selected keyframe, which
    -- is exactly what the button promises.
    local items = convertAll(spr)
    local batchName = source and source.name or "Imported"

    -- One click anchors the whole batch. Asking per image would mean ten
    -- clicks for ten frames, and an animation wants them aligned anyway.
    local function commit(anchor)
      for _, item in ipairs(items) do
        item.pos = anchor and place.centeredOn(item.image, anchor)
                          or  anchoredPosition(spr, item.image, mode)
      end

      if spread == "layers" then
        place.asLayers(spr, items)
      else
        place.asFrames(spr, items, target, batchName)
      end
    end

    if mode == "cursor" then
      local title = (#items == 1) and ("Click to place " .. batchName)
                                  or  ("Click to place " .. #items .. " images")
      -- The crosshair outlives this window: the callback places whenever the
      -- artist gets round to clicking.
      if place.pickPoint(title, commit) then
        closeDialog()
        return
      end
    end

    commit(nil)
    closeDialog()
  end

  local function onLimitToggled()
    preserveBounds(function()
      dlg:modify{ id = "colors", enabled = dlg.data.limit }
      recompute()
    end)
  end

  dlg = Dialog{ title = "Pixel Import" }

  -- Choosing what to look at comes before looking at it.
  dlg:button{ id = "import", text = "Import Image", onclick = doImport }

  local startLabels = imageLabels(sources)
  dlg:combobox{ id = "image", label = "Image", options = startLabels,
                option = startLabels[math.min(selected, #startLabels)],
                onchange = onImageChanged }

  dlg:canvas{ id = "canvas", width = PREVIEW_W, height = PREVIEW_H, onpaint = paint }

  -- Each field gets its own label rather than sharing a "Target" row with an
  -- "x" between them. This dialog puts every widget on a line of its own -
  -- a plain second field, a label, and a drawn canvas were all tried as the
  -- separator and all three ended up stacked - so the honest fix is to name
  -- the two lines instead of pretending they are one.
  dlg:label{ id = "srcSize", label = "Source", text = "-" }
  dlg:number{ id = "targetW", label = "Width", text = "0", decimals = 0,
              onchange = function() onTargetEdited("w") end }
  dlg:number{ id = "targetH", label = "Height", text = "0", decimals = 0,
              onchange = function() onTargetEdited("h") end }

  dlg:slider{ id = "scale", label = "Scale", min = 1, max = 100,
              value = remembered.scale or 50, onchange = onScaleChanged }
  dlg:separator()

  -- Layout follows the pipeline: what came in, how it is converted, where it
  -- goes. The destination controls sit directly above the button that acts on
  -- them, rather than being separated from it by every conversion setting.
  local modeLabels    = labelsOf(MODES)
  local methodLabels  = convert.methodLabels()
  local paletteLabels = labelsOf(PALETTES)
  local spreadLabels  = labelsOf(DISTRIBUTE)
  -- "Resample", not "Downscale": this picks how pixels are combined, and at
  -- full scale on detected pixel art it is not scaling anything at all.
  dlg:combobox{ id = "method", label = "Resample", options = methodLabels,
                option = pick(methodLabels, remembered.method, methodLabels[1]),
                onchange = function() recompute() end }
  dlg:separator()

  dlg:combobox{ id = "palette", label = "Palette", options = paletteLabels,
                option = pick(paletteLabels, remembered.palette, paletteLabels[1]),
                onchange = function() recompute() end }
  dlg:check{ id = "limit", label = "", text = "Limit color palette",
             selected = remembered.limit ~= false, onclick = onLimitToggled }
  dlg:slider{ id = "colors", label = "", min = 2, max = 64,
              value = remembered.colors or 16, onchange = function() recompute() end }
  dlg:separator()

  dlg:combobox{ id = "placement", label = "Position", options = modeLabels,
                option = pick(modeLabels, remembered.placement, modeLabels[1]),
                onchange = remember }
  dlg:combobox{ id = "distribute", label = "Place", options = spreadLabels,
                option = pick(spreadLabels, remembered.distribute, spreadLabels[1]),
                onchange = remember }
  dlg:separator()

  dlg:button{ id = "place", text = "Place on Selected Keyframe",
              onclick = doPlace, enabled = false }

  -- Non-modal on purpose: placing with the cursor means clicking on the
  -- canvas, which a modal dialog would swallow.
  dlg:show{ wait = false }

  -- Restore after showing, not before: repainting a dialog that has not been
  -- shown yet has nothing to paint into.
  dlg:modify{ id = "colors", enabled = dlg.data.limit }
  dlg:modify{ id = "distribute", enabled = #sources > 1 }

  if #sources > 0 then
    dlg:modify{ id = "place", enabled = true }
    selectImage(selected)
  end
end

return ui
