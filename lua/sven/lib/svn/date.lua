---Helpers for the ISO 8601 UTC timestamps svn prints in its XML output
---(`2026-10-12T20:31:44.107693Z`).
---@class SvenDate
local M = {}

---Days since 1970-01-01 for a proleptic Gregorian date
---@param year number
---@param month number
---@param day number
---@return number
local function days_from_civil(year, month, day)
  if month <= 2 then
    year = year - 1
  end

  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local doy = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy

  return era * 146097 + doe - 719468
end

---@param iso string|nil Timestamp as printed by svn
---@return number|nil unix Seconds since the epoch, nil when `iso` cannot be parsed
function M.parse(iso)
  if type(iso) ~= "string" then
    return nil
  end

  local year, month, day, hour, min, sec = iso:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
  if not year then
    return nil
  end

  -- The pattern only matches digits, so these are numbers
  local n = function(digits)
    return tonumber(digits) --[[@as number]]
  end

  return days_from_civil(n(year), n(month), n(day)) * 86400 + n(hour) * 3600 + n(min) * 60 + n(sec)
end

---@param count number
---@param unit string
---@return string
local function plural(count, unit)
  return ("%d %s%s"):format(count, unit, count == 1 and "" or "s")
end

---Formats a point in time relative to now, the way `git log --date=relative` does:
---"5 minutes ago", "3 days ago", "1 year, 2 months ago".
---@param unix number|nil Seconds since the epoch
---@param now number|nil Defaults to the current time
---@return string
function M.relative(unix, now)
  if not unix then
    return ""
  end

  local diff = (now or os.time()) - unix
  if diff < 0 then
    return "in the future"
  end

  if diff < 90 then
    return plural(diff, "second") .. " ago"
  end

  local minutes = math.floor((diff + 30) / 60)
  if minutes < 90 then
    return plural(minutes, "minute") .. " ago"
  end

  local hours = math.floor((minutes + 30) / 60)
  if hours < 36 then
    return plural(hours, "hour") .. " ago"
  end

  local days = math.floor((hours + 12) / 24)
  if days < 14 then
    return plural(days, "day") .. " ago"
  end

  if days < 70 then
    return plural(math.floor((days + 3) / 7), "week") .. " ago"
  end

  if days < 365 then
    return plural(math.floor((days + 15) / 30), "month") .. " ago"
  end

  if days < 1825 then
    local total_months = math.floor((days * 12 * 2 + 365) / (365 * 2))
    local years = math.floor(total_months / 12)
    local months = total_months % 12
    if months > 0 then
      return ("%s, %s ago"):format(plural(years, "year"), plural(months, "month"))
    else
      return plural(years, "year") .. " ago"
    end
  end

  return plural(math.floor((days + 183) / 365), "year") .. " ago"
end

---Formats a point in time in the local timezone
---@param unix number|nil Seconds since the epoch
---@param format string|nil strftime format. Defaults to "%Y-%m-%d %H:%M"
---@return string
function M.format(unix, format)
  if not unix then
    return ""
  end

  return os.date(format or "%Y-%m-%d %H:%M", unix) --[[@as string]]
end

return M
