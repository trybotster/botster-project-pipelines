local repo = require("project_pipelines.repo")
local ui = require("project_pipelines.web.ui")

local M = {}

function M.render()
  local context = repo.current_context()
  return ui.node("screen", "project-pipelines-settings", {
    title = "Project Pipelines Settings",
    surface_id = "project-pipelines.settings",
    package_name = "project-pipelines",
    storage = "plugin_db",
    state_counts = {
      projects = #context.projects,
      tickets = #context.tickets,
      pipeline_definitions = #context.pipeline_definitions,
      runs = #context.runs,
      artifacts = #context.artifacts,
      questions = #context.questions,
    },
  }, {
    ui.text("project-pipelines-settings-storage", "Runtime state is persisted by the plugin database capability."),
  })
end

return M
