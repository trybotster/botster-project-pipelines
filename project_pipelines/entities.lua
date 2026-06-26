local repo = require("project_pipelines.repo")

local M = {}

local function frame(family, record)
  return {
    type = "entity_upsert",
    family = "project-pipelines." .. family,
    id = record.id,
    record = record,
  }
end

function M.snapshot()
  local context = repo.current_context()
  local frames = {}
  for _, project in ipairs(context.projects) do
    table.insert(frames, frame("project", project))
  end
  for _, ticket in ipairs(context.tickets) do
    table.insert(frames, frame("ticket", ticket))
  end
  for _, pipeline in ipairs(context.pipeline_definitions) do
    table.insert(frames, frame("pipeline_definition", pipeline))
  end
  for _, run in ipairs(context.runs) do
    table.insert(frames, frame("run", run))
  end
  return {
    ok = true,
    frames = frames,
  }
end

return M
