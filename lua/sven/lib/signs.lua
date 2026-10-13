local M = {}

local signs = { SvenBlank = " " }

function M.get(name)
  local sign = signs[name]
  if sign == "" then
    return " "
  else
    return sign
  end
end

function M.setup(config)
  if not config.disable_signs then
    for key, val in pairs(config.signs) do
      if key == "hunk" or key == "item" or key == "section" then
        signs["SvenClosed" .. key] = val[1]
        signs["SvenOpen" .. key] = val[2]
      end
    end
  end
end

return M
