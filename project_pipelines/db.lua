local util = require("project_pipelines.util")

local M = {}

local STATE_KEY = "state"

local function default_state()
  return {
    schema_version = 1,
    counters = {
      project = 0,
      ticket = 0,
      pipeline_definition = 0,
      run = 0,
      artifact = 0,
      question = 0,
      event = 0,
    },
    projects = {},
    tickets = {},
    pipeline_definitions = {},
    runs = {},
    artifacts = {},
    questions = {},
    events = {},
  }
end

local function plugin_db()
  return botster
    and botster.capabilities
    and botster.capabilities.plugin_db
end

function M.load()
  local db = plugin_db()
  if not db or type(db.get) ~= "function" then
    return default_state()
  end

  local ok, result = pcall(db.get, { key = STATE_KEY })
  if not ok or type(result) ~= "table" or type(result.record) ~= "table" then
    return default_state()
  end

  local payload = result.record.payload
  if type(payload) ~= "table" then
    return default_state()
  end

  local state = util.copy(payload)
  state.schema_version = state.schema_version or 1
  state.counters = state.counters or {}
  state.projects = state.projects or {}
  state.tickets = state.tickets or {}
  state.pipeline_definitions = state.pipeline_definitions or {}
  state.runs = state.runs or {}
  state.artifacts = state.artifacts or {}
  state.questions = state.questions or {}
  state.events = state.events or {}
  return state
end

function M.save(state)
  local db = plugin_db()
  if not db or type(db.set) ~= "function" then
    return nil, "plugin_db capability is unavailable"
  end

  local ok, result = pcall(db.set, {
    key = STATE_KEY,
    schema_version = 1,
    payload = state,
  })
  if not ok then
    return nil, result
  end
  return result or true, nil
end

function M.reset()
  local state = default_state()
  local _, err = M.save(state)
  if err then
    return nil, err
  end
  return state
end

function M.next_id(state, kind)
  state.counters[kind] = (state.counters[kind] or 0) + 1
  return kind .. "_" .. state.counters[kind]
end

return M
