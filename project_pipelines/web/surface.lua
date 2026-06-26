local home = require("project_pipelines.web.screens.home")
local settings = require("project_pipelines.web.screens.settings")

local M = {}

function M.render_home()
  return home.render()
end

function M.render_settings()
  return settings.render()
end

function M.handlers()
  return {
    {
      id = "home_surface",
      kind = "surface_route",
      descriptor_id = "project-pipelines.home",
      descriptor = {
        title = "Project Pipelines",
        surface_id = "project-pipelines.home",
      },
      call = M.render_home,
    },
    {
      id = "settings_surface",
      kind = "surface_route",
      descriptor_id = "project-pipelines.settings",
      descriptor = {
        title = "Project Pipelines Settings",
        surface_id = "project-pipelines.settings",
      },
      call = M.render_settings,
    },
  }
end

return M
