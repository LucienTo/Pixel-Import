-- Pixel Import - bring an image into Aseprite as editable pixel art.

local ROOT = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")

local cache = {}
local function load(name)
  if cache[name] ~= nil then return cache[name] end
  local ok, mod = pcall(dofile, ROOT .. "/src/" .. name .. ".lua")
  if not ok then
    app.alert{
      title = "Pixel Import - Load Error",
      text = { "Failed to load module: " .. name, "", tostring(mod) },
    }
    cache[name] = false
    return nil
  end
  cache[name] = mod
  return mod
end

function init(plugin)
  plugin:newCommand{
    id = "PixelImportOpen",
    title = "Pixel Import: Convert Image",
    group = "file_scripts",
    onclick = function()
      local ui = load("ui")
      if ui then ui.open() end
    end,
  }
end

function exit(plugin)
end
