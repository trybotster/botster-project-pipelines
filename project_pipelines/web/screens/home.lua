local repo = require("project_pipelines.repo")
local ui = require("project_pipelines.web.ui")

local M = {}

function M.render()
  local context = repo.current_context()
  return ui.node("screen", "project-pipelines-home", {
    title = "Project Pipelines",
    surface_id = "project-pipelines.home",
    state_counts = {
      projects = #context.projects,
      tickets = #context.tickets,
      runs = #context.runs,
    },
    bindings = {
      { family = "project-pipelines.project" },
      { family = "project-pipelines.ticket" },
      { family = "project-pipelines.run" },
    },
  }, {
    ui.node("section", "project-pipelines-projects", { title = "Projects" }, {
      ui.bound_list("project-pipelines-project-list", "project-pipelines.project", "No projects"),
    }),
    ui.node("section", "project-pipelines-tickets", { title = "Tickets" }, {
      ui.bound_list("project-pipelines-ticket-list", "project-pipelines.ticket", "No tickets"),
    }),
  })
end

return M
