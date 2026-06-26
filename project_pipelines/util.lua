local M = {}

function M.trim(value)
  if type(value) ~= "string" then
    return nil
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.string_arg(arguments, key)
  local value = arguments and arguments[key]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

function M.table_arg(arguments, key)
  local value = arguments and arguments[key]
  if type(value) == "table" then
    return value
  end
  return nil
end

function M.array(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

function M.copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = M.copy(nested)
  end
  return result
end

function M.sort_by_position(records)
  table.sort(records, function(left, right)
    return (left.position or 0) < (right.position or 0)
  end)
  return records
end

function M.ok(payload)
  payload = payload or {}
  payload.ok = true
  return payload
end

function M.error(code, message, fields)
  return {
    ok = false,
    error = {
      code = code,
      message = message,
      fields = fields or {},
    },
  }
end

return M
