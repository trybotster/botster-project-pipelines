local repo = require("project_pipelines.repo")

local M = {}

M.create_project = repo.create_project
M.list_projects = repo.list_projects
M.show_project = repo.show_project
M.create_ticket = repo.create_ticket
M.list_tickets = repo.list_tickets
M.show_ticket = repo.show_ticket
M.define_pipeline = repo.define_pipeline
M.list_pipeline_definitions = repo.list_pipeline_definitions
M.show_pipeline_definition = repo.show_pipeline_definition
M.record_run = repo.record_run
M.record_artifact = repo.record_artifact
M.record_question = repo.record_question
M.current_context = repo.current_context
M.reset = repo.reset

return M
