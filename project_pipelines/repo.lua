local db = require("project_pipelines.db")
local util = require("project_pipelines.util")

local M = {}

local VALID_STATUSES = {
  open = true,
  active = true,
  blocked = true,
  ready_for_review = true,
  done = true,
  closed = true,
}

local function persist(state)
  local _, err = db.save(state)
  if err then
    return util.error("persist_failed", "failed to persist Project Pipelines state: " .. tostring(err))
  end
  return nil
end

local function find_by_id(records, id)
  for _, record in ipairs(records) do
    if record.id == id then
      return record
    end
  end
  return nil
end

local function require_string(arguments, key)
  local value = util.trim(arguments and arguments[key])
  if not value or value == "" then
    return nil, key .. " is required"
  end
  return value
end

local function repository_from(arguments)
  local repository = util.table_arg(arguments, "repository") or {}
  repository = {
    id = util.trim(repository.id or arguments.repository_id),
    name = util.trim(repository.name or arguments.repository_name),
    remote = util.trim(repository.remote or arguments.repository_remote),
  }

  local missing = {}
  if not repository.id or repository.id == "" then table.insert(missing, "repository.id") end
  if not repository.name or repository.name == "" then table.insert(missing, "repository.name") end
  if not repository.remote or repository.remote == "" then table.insert(missing, "repository.remote") end
  if #missing > 0 then
    return nil, missing
  end
  return repository, nil
end

local function push_event(state, kind, run_id, subject_id)
  local event = {
    id = db.next_id(state, "event"),
    kind = kind,
    run_id = run_id,
    subject_id = subject_id,
  }
  table.insert(state.events, event)
  return event
end

function M.list_projects()
  return util.ok({ projects = db.load().projects })
end

function M.show_project(arguments)
  local id = util.string_arg(arguments, "project_id") or util.string_arg(arguments, "id")
  if not id then
    return util.error("missing_argument", "project_id is required")
  end
  local project = find_by_id(db.load().projects, id)
  if not project then
    return util.error("not_found", "project not found: " .. id)
  end
  return util.ok({ project = project })
end

function M.create_project(arguments)
  arguments = arguments or {}
  local name, name_err = require_string(arguments, "name")
  if name_err then
    return util.error("validation_failed", name_err, { "name" })
  end

  local repository, missing = repository_from(arguments)
  if missing then
    return util.error("validation_failed", "repository id, name, and remote are required", missing)
  end

  local spawn_target_id, spawn_err = require_string(arguments, "spawn_target_id")
  if spawn_err then
    return util.error("validation_failed", spawn_err, { "spawn_target_id" })
  end

  local state = db.load()
  local project = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "project"),
    mode = util.string_arg(arguments, "workspace_id") and "workspace_linked" or "standalone",
    name = name,
    repository = repository,
    spawn_target_id = spawn_target_id,
    workspace_id = util.string_arg(arguments, "workspace_id"),
  }
  table.insert(state.projects, project)
  local err = persist(state)
  if err then return err end
  return util.ok({ project = project })
end

function M.list_tickets(arguments)
  local state = db.load()
  local project_id = util.string_arg(arguments, "project_id")
  if not project_id then
    return util.ok({ tickets = state.tickets })
  end
  local tickets = {}
  for _, ticket in ipairs(state.tickets) do
    if ticket.project_id == project_id then
      table.insert(tickets, ticket)
    end
  end
  return util.ok({ tickets = tickets })
end

function M.show_ticket(arguments)
  local id = util.string_arg(arguments, "ticket_id") or util.string_arg(arguments, "id")
  if not id then
    return util.error("missing_argument", "ticket_id is required")
  end
  local ticket = find_by_id(db.load().tickets, id)
  if not ticket then
    return util.error("not_found", "ticket not found: " .. id)
  end
  return util.ok({ ticket = ticket })
end

function M.create_ticket(arguments)
  arguments = arguments or {}
  local project_id, project_err = require_string(arguments, "project_id")
  if project_err then
    return util.error("validation_failed", project_err, { "project_id" })
  end
  local title, title_err = require_string(arguments, "title")
  if title_err then
    return util.error("validation_failed", title_err, { "title" })
  end

  local state = db.load()
  local project = find_by_id(state.projects, project_id)
  if not project then
    return util.error("not_found", "project not found: " .. project_id)
  end

  local status = util.string_arg(arguments, "status") or "open"
  if not VALID_STATUSES[status] then
    return util.error("validation_failed", "ticket status is invalid", { "status" })
  end

  local ticket = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "ticket"),
    project_id = project_id,
    workspace_id = util.string_arg(arguments, "workspace_id"),
    title = title,
    description = util.string_arg(arguments, "description"),
    status = status,
    dependency_ticket_ids = util.array(arguments.dependency_ticket_ids),
  }
  table.insert(state.tickets, ticket)
  push_event(state, "ticket_created", nil, ticket.id)
  local err = persist(state)
  if err then return err end
  return util.ok({ ticket = ticket })
end

function M.define_pipeline(arguments)
  arguments = arguments or {}
  local project_id, project_err = require_string(arguments, "project_id")
  if project_err then
    return util.error("validation_failed", project_err, { "project_id" })
  end
  local name, name_err = require_string(arguments, "name")
  if name_err then
    return util.error("validation_failed", name_err, { "name" })
  end

  local state = db.load()
  if not find_by_id(state.projects, project_id) then
    return util.error("not_found", "project not found: " .. project_id)
  end

  local steps = util.array(arguments.steps)
  for index, step in ipairs(steps) do
    step.id = step.id or ("step_" .. index)
    step.position = step.position or index
    step.gates = util.array(step.gates)
  end
  util.sort_by_position(steps)

  local pipeline = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "pipeline_definition"),
    project_id = project_id,
    name = name,
    steps = steps,
  }
  table.insert(state.pipeline_definitions, pipeline)
  local err = persist(state)
  if err then return err end
  return util.ok({ pipeline_definition = pipeline })
end

function M.list_pipeline_definitions()
  return util.ok({ pipeline_definitions = db.load().pipeline_definitions })
end

function M.show_pipeline_definition(arguments)
  local id = util.string_arg(arguments, "pipeline_definition_id") or util.string_arg(arguments, "id")
  if not id then
    return util.error("missing_argument", "pipeline_definition_id is required")
  end
  local pipeline = find_by_id(db.load().pipeline_definitions, id)
  if not pipeline then
    return util.error("not_found", "pipeline definition not found: " .. id)
  end
  return util.ok({ pipeline_definition = pipeline })
end

function M.record_run(arguments)
  arguments = arguments or {}
  local ticket_id, ticket_err = require_string(arguments, "ticket_id")
  if ticket_err then
    return util.error("validation_failed", ticket_err, { "ticket_id" })
  end
  local pipeline_id, pipeline_err = require_string(arguments, "pipeline_definition_id")
  if pipeline_err then
    return util.error("validation_failed", pipeline_err, { "pipeline_definition_id" })
  end

  local state = db.load()
  if not find_by_id(state.tickets, ticket_id) then
    return util.error("not_found", "ticket not found: " .. ticket_id)
  end
  local pipeline = find_by_id(state.pipeline_definitions, pipeline_id)
  if not pipeline then
    return util.error("not_found", "pipeline definition not found: " .. pipeline_id)
  end
  local first_step = pipeline.steps[1] or { id = nil }
  local run = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "run"),
    ticket_id = ticket_id,
    pipeline_definition_id = pipeline_id,
    current_step_id = util.string_arg(arguments, "current_step_id") or first_step.id,
    status = util.string_arg(arguments, "status") or "active",
    workspace_session_group_id = util.string_arg(arguments, "workspace_session_group_id"),
    branch = util.string_arg(arguments, "branch"),
    base_ref = util.string_arg(arguments, "base_ref") or "main",
    worktree = arguments.worktree or { kind = "provider_owned_reference", id = util.string_arg(arguments, "worktree_id") },
  }
  table.insert(state.runs, run)
  push_event(state, "run_started", run.id, run.id)
  local err = persist(state)
  if err then return err end
  return util.ok({ run = run })
end

function M.record_artifact(arguments)
  arguments = arguments or {}
  local run_id, run_err = require_string(arguments, "run_id")
  if run_err then
    return util.error("validation_failed", run_err, { "run_id" })
  end
  local state = db.load()
  if not find_by_id(state.runs, run_id) then
    return util.error("not_found", "run not found: " .. run_id)
  end
  local artifact = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "artifact"),
    run_id = run_id,
    step_id = util.string_arg(arguments, "step_id"),
    kind = util.string_arg(arguments, "kind") or "report",
    summary = util.string_arg(arguments, "summary"),
    uri = util.string_arg(arguments, "uri"),
  }
  table.insert(state.artifacts, artifact)
  push_event(state, "artifact_added", run_id, artifact.id)
  local err = persist(state)
  if err then return err end
  return util.ok({ artifact = artifact })
end

function M.record_question(arguments)
  arguments = arguments or {}
  local run_id, run_err = require_string(arguments, "run_id")
  if run_err then
    return util.error("validation_failed", run_err, { "run_id" })
  end
  local question_text, question_err = require_string(arguments, "question")
  if question_err then
    return util.error("validation_failed", question_err, { "question" })
  end
  local state = db.load()
  if not find_by_id(state.runs, run_id) then
    return util.error("not_found", "run not found: " .. run_id)
  end
  local question = {
    id = util.string_arg(arguments, "id") or db.next_id(state, "question"),
    run_id = run_id,
    ticket_id = util.string_arg(arguments, "ticket_id"),
    step_id = util.string_arg(arguments, "step_id"),
    status = util.string_arg(arguments, "status") or "open",
    question = question_text,
  }
  table.insert(state.questions, question)
  push_event(state, "question_asked", run_id, question.id)
  local err = persist(state)
  if err then return err end
  return util.ok({ question = question })
end

function M.current_context()
  local state = db.load()
  return util.ok({
    projects = state.projects,
    tickets = state.tickets,
    pipeline_definitions = state.pipeline_definitions,
    runs = state.runs,
    artifacts = state.artifacts,
    questions = state.questions,
    events = state.events,
  })
end

function M.reset()
  local state, err = db.reset()
  if err then
    return util.error("persist_failed", "failed to reset Project Pipelines state: " .. tostring(err))
  end
  return util.ok({ state = state })
end

return M
