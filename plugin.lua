local STATE_KEY = "state"

local function empty_schema()
  return { type = "object", properties = {}, additionalProperties = false }
end

local function object_schema(properties, required)
  return {
    type = "object",
    properties = properties,
    required = required or {},
    additionalProperties = true,
  }
end

local function trim(value)
  if type(value) ~= "string" then return nil end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function string_arg(arguments, key)
  local value = arguments and arguments[key]
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function table_arg(arguments, key)
  local value = arguments and arguments[key]
  if type(value) == "table" then return value end
  return nil
end

local function array(value)
  if type(value) == "table" then return value end
  return {}
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = copy(nested)
  end
  return result
end

local function ok(payload)
  payload = payload or {}
  payload.ok = true
  return payload
end

local function failure(code, message, fields)
  return {
    ok = false,
    error = { code = code, message = message, fields = fields or {} },
  }
end

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
      session_request = 0,
    },
    projects = {},
    tickets = {},
    pipeline_definitions = {},
    runs = {},
    artifacts = {},
    questions = {},
    events = {},
    session_requests = {},
  }
end

local function load_state()
  local plugin_db = botster and botster.capabilities and botster.capabilities.plugin_db
  if not plugin_db or type(plugin_db.get) ~= "function" then return default_state() end
  local loaded = plugin_db.get({ key = STATE_KEY })
  if type(loaded) ~= "table" or type(loaded.record) ~= "table" or type(loaded.record.payload) ~= "table" then
    return default_state()
  end
  local state = copy(loaded.record.payload)
  state.counters = state.counters or {}
  state.projects = state.projects or {}
  state.tickets = state.tickets or {}
  state.pipeline_definitions = state.pipeline_definitions or {}
  state.runs = state.runs or {}
  state.artifacts = state.artifacts or {}
  state.questions = state.questions or {}
  state.events = state.events or {}
  state.session_requests = state.session_requests or {}
  return state
end

local function save_state(state)
  local plugin_db = botster and botster.capabilities and botster.capabilities.plugin_db
  if not plugin_db or type(plugin_db.set) ~= "function" then
    return failure("persist_failed", "plugin_db capability is unavailable")
  end
  plugin_db.set({ key = STATE_KEY, schema_version = 1, payload = state })
  return nil
end

local function next_id(state, kind)
  state.counters[kind] = (state.counters[kind] or 0) + 1
  return kind .. "_" .. state.counters[kind]
end

local function find_by_id(records, id)
  for _, record in ipairs(records) do
    if record.id == id then return record end
  end
  return nil
end

local function push_event(state, kind, run_id, subject_id, payload)
  table.insert(state.events, {
    id = next_id(state, "event"),
    kind = kind,
    run_id = run_id,
    subject_id = subject_id,
    payload = payload,
  })
end

local function find_project_for_ticket(state, ticket)
  if not ticket then return nil end
  return find_by_id(state.projects, ticket.project_id)
end

local function find_pipeline_step(pipeline, step_id)
  if not pipeline then return nil end
  for _, step in ipairs(array(pipeline.steps)) do
    if step.id == step_id then return step end
  end
  return nil
end

local function step_uses_session_template(step)
  if type(step) ~= "table" then return false end
  local mode = step.kind or step.execution or step.run_mode or step.mode
  return step.session_template_id and (mode == "pty" or mode == "session" or mode == "session_template")
end

local function bounded_prompt(prompt)
  if type(prompt) ~= "string" then return nil end
  if #prompt <= 500 then return prompt end
  return prompt:sub(1, 497) .. "..."
end

local function clean_metadata(metadata)
  local result = {}
  if type(metadata) ~= "table" then return result end
  for key, value in pairs(metadata) do
    if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
      result[key] = value
    end
  end
  return result
end

local function context_value(arguments, run, ticket, project, step, key)
  local explicit = arguments and arguments[key]
  if explicit ~= nil then return explicit end
  if run and run[key] ~= nil then return run[key] end
  if ticket and ticket[key] ~= nil then return ticket[key] end
  if project and project[key] ~= nil then return project[key] end
  if step and step[key] ~= nil then return step[key] end
  return nil
end

local function build_session_template_request(arguments, run, ticket, project, step)
  local repository = context_value(arguments, run, ticket, project, step, "repository")
  local worktree = context_value(arguments, run, ticket, project, step, "worktree")
  local prompt = bounded_prompt(context_value(arguments, run, ticket, project, step, "prompt"))
  local metadata = clean_metadata(context_value(arguments, run, ticket, project, step, "metadata"))
  metadata.owner_plugin = metadata.owner_plugin or "project-pipelines"
  metadata.surface = metadata.surface or "project-pipelines"
  metadata.run_id = run.id
  metadata.step_id = step.id
  metadata.ticket_id = ticket.id

  local context = {
    worktree_path = type(worktree) == "table" and worktree.path or nil,
    repo_path = type(repository) == "table" and repository.path or nil,
    branch_name = context_value(arguments, run, ticket, project, step, "branch") or run.branch,
    prompt = prompt,
    ticket_id = ticket.id,
    workspace_id = context_value(arguments, run, ticket, project, step, "workspace_id"),
    metadata = metadata,
  }
  if context.workspace_id == nil then context.workspace_id = project.workspace_id or ticket.workspace_id end

  return {
    target_id = context_value(arguments, run, ticket, project, step, "spawn_target_id") or project.spawn_target_id,
    cwd = context_value(arguments, run, ticket, project, step, "cwd"),
    environment = context_value(arguments, run, ticket, project, step, "environment") or {},
    context = context,
  }
end

local function spawn_session_template(template_id, session_id, request)
  local capabilities = botster and botster.capabilities or {}
  local hub_client = capabilities.hub_client or capabilities.hub
  if hub_client and type(hub_client.spawn_session_template) == "function" then
    return hub_client.spawn_session_template({
      template_id = template_id,
      session_id = session_id,
      request = request,
    })
  end
  local session_templates = capabilities.session_templates
  if session_templates and type(session_templates.spawn_session_template) == "function" then
    return session_templates.spawn_session_template(template_id, session_id, request)
  end
  return failure("session_templates_unavailable", "hub session template spawn capability is unavailable")
end

local function repository_from(arguments)
  local repository = table_arg(arguments, "repository") or {}
  repository = {
    id = trim(repository.id or arguments.repository_id),
    name = trim(repository.name or arguments.repository_name),
    remote = trim(repository.remote or arguments.repository_remote),
  }
  local missing = {}
  if not repository.id or repository.id == "" then table.insert(missing, "repository.id") end
  if not repository.name or repository.name == "" then table.insert(missing, "repository.name") end
  if not repository.remote or repository.remote == "" then table.insert(missing, "repository.remote") end
  if #missing > 0 then return nil, missing end
  return repository, nil
end

local function create_project(arguments)
  arguments = arguments or {}
  local name = trim(arguments.name)
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local repository, missing = repository_from(arguments)
  if missing then return failure("validation_failed", "repository id, name, and remote are required", missing) end
  local spawn_target_id = trim(arguments.spawn_target_id)
  if not spawn_target_id or spawn_target_id == "" then
    return failure("validation_failed", "spawn_target_id is required", { "spawn_target_id" })
  end

  local state = load_state()
  local project = {
    id = string_arg(arguments, "id") or next_id(state, "project"),
    mode = string_arg(arguments, "workspace_id") and "workspace_linked" or "standalone",
    name = name,
    repository = repository,
    spawn_target_id = spawn_target_id,
    workspace_id = string_arg(arguments, "workspace_id"),
  }
  table.insert(state.projects, project)
  local err = save_state(state)
  if err then return err end
  return ok({ project = project })
end

local function list_projects()
  return ok({ projects = load_state().projects })
end

local function show_project(arguments)
  local id = string_arg(arguments, "project_id") or string_arg(arguments, "id")
  if not id then return failure("missing_argument", "project_id is required") end
  local project = find_by_id(load_state().projects, id)
  if not project then return failure("not_found", "project not found: " .. id) end
  return ok({ project = project })
end

local function create_ticket(arguments)
  arguments = arguments or {}
  local project_id = trim(arguments.project_id)
  if not project_id or project_id == "" then return failure("validation_failed", "project_id is required", { "project_id" }) end
  local title = trim(arguments.title)
  if not title or title == "" then return failure("validation_failed", "title is required", { "title" }) end
  local state = load_state()
  if not find_by_id(state.projects, project_id) then return failure("not_found", "project not found: " .. project_id) end
  local ticket = {
    id = string_arg(arguments, "id") or next_id(state, "ticket"),
    project_id = project_id,
    workspace_id = string_arg(arguments, "workspace_id"),
    title = title,
    description = string_arg(arguments, "description"),
    status = string_arg(arguments, "status") or "open",
    dependency_ticket_ids = array(arguments.dependency_ticket_ids),
  }
  table.insert(state.tickets, ticket)
  push_event(state, "ticket_created", nil, ticket.id)
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function list_tickets(arguments)
  local state = load_state()
  local project_id = string_arg(arguments or {}, "project_id")
  if not project_id then return ok({ tickets = state.tickets }) end
  local tickets = {}
  for _, ticket in ipairs(state.tickets) do
    if ticket.project_id == project_id then table.insert(tickets, ticket) end
  end
  return ok({ tickets = tickets })
end

local function show_ticket(arguments)
  local id = string_arg(arguments, "ticket_id") or string_arg(arguments, "id")
  if not id then return failure("missing_argument", "ticket_id is required") end
  local ticket = find_by_id(load_state().tickets, id)
  if not ticket then return failure("not_found", "ticket not found: " .. id) end
  return ok({ ticket = ticket })
end

local function define_pipeline(arguments)
  arguments = arguments or {}
  local project_id = trim(arguments.project_id)
  if not project_id or project_id == "" then return failure("validation_failed", "project_id is required", { "project_id" }) end
  local name = trim(arguments.name)
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local state = load_state()
  if not find_by_id(state.projects, project_id) then return failure("not_found", "project not found: " .. project_id) end
  local steps = array(arguments.steps)
  for index, step in ipairs(steps) do
    step.id = step.id or ("step_" .. index)
    step.position = step.position or index
    step.gates = array(step.gates)
  end
  local pipeline = {
    id = string_arg(arguments, "id") or next_id(state, "pipeline_definition"),
    project_id = project_id,
    name = name,
    steps = steps,
  }
  table.insert(state.pipeline_definitions, pipeline)
  local err = save_state(state)
  if err then return err end
  return ok({ pipeline_definition = pipeline })
end

local function list_pipeline_definitions()
  return ok({ pipeline_definitions = load_state().pipeline_definitions })
end

local function show_pipeline_definition(arguments)
  local id = string_arg(arguments, "pipeline_definition_id") or string_arg(arguments, "id")
  if not id then return failure("missing_argument", "pipeline_definition_id is required") end
  local pipeline = find_by_id(load_state().pipeline_definitions, id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. id) end
  return ok({ pipeline_definition = pipeline })
end

local function record_run(arguments)
  arguments = arguments or {}
  local state = load_state()
  local ticket_id = trim(arguments.ticket_id)
  local pipeline_id = trim(arguments.pipeline_definition_id)
  if not ticket_id or ticket_id == "" then return failure("validation_failed", "ticket_id is required", { "ticket_id" }) end
  if not pipeline_id or pipeline_id == "" then return failure("validation_failed", "pipeline_definition_id is required", { "pipeline_definition_id" }) end
  if not find_by_id(state.tickets, ticket_id) then return failure("not_found", "ticket not found: " .. ticket_id) end
  local pipeline = find_by_id(state.pipeline_definitions, pipeline_id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. pipeline_id) end
  local first_step = pipeline.steps[1] or {}
  local run = {
    id = string_arg(arguments, "id") or next_id(state, "run"),
    ticket_id = ticket_id,
    pipeline_definition_id = pipeline_id,
    current_step_id = string_arg(arguments, "current_step_id") or first_step.id,
    status = string_arg(arguments, "status") or "active",
    workspace_session_group_id = string_arg(arguments, "workspace_session_group_id"),
    workspace_id = string_arg(arguments, "workspace_id"),
    repository = arguments.repository,
    spawn_target_id = string_arg(arguments, "spawn_target_id"),
    branch = string_arg(arguments, "branch"),
    base_ref = string_arg(arguments, "base_ref") or "main",
    worktree = arguments.worktree or { kind = "provider_owned_reference", id = string_arg(arguments, "worktree_id") },
  }
  table.insert(state.runs, run)
  push_event(state, "run_started", run.id, run.id)
  local err = save_state(state)
  if err then return err end
  return ok({ run = run })
end

local function activate_step(arguments)
  arguments = arguments or {}
  local run_id = trim(arguments.run_id)
  if not run_id or run_id == "" then return failure("validation_failed", "run_id is required", { "run_id" }) end
  local state = load_state()
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  local ticket = find_by_id(state.tickets, run.ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. run.ticket_id) end
  local project = find_project_for_ticket(state, ticket)
  if not project then return failure("not_found", "project not found: " .. ticket.project_id) end
  local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. run.pipeline_definition_id) end
  local step_id = string_arg(arguments, "step_id") or run.current_step_id
  local step = find_pipeline_step(pipeline, step_id)
  if not step then return failure("not_found", "step not found: " .. tostring(step_id)) end

  run.current_step_id = step.id
  push_event(state, "step_started", run.id, step.id)

  if not step_uses_session_template(step) then
    local activation = {
      run_id = run.id,
      step_id = step.id,
      spawned = false,
      status = "preserved_non_pty",
      reason = "step is not a PTY-backed session-template step",
    }
    push_event(state, "step_activation_preserved", run.id, step.id, activation)
    local err = save_state(state)
    if err then return err end
    return ok({ activation = activation, run = run })
  end

  local request_id = string_arg(arguments, "request_id") or next_id(state, "session_request")
  local session_id = string_arg(arguments, "session_id")
  local request = build_session_template_request(arguments, run, ticket, project, step)
  if not request.target_id or request.target_id == "" then
    return failure("validation_failed", "spawn target is required for session-template activation", { "target_id" })
  end
  local response = spawn_session_template(step.session_template_id, session_id, request)
  local status = response and response.ok == false and "failed" or "spawn_requested"
  local session_request = {
    id = request_id,
    run_id = run.id,
    step_id = step.id,
    ticket_id = ticket.id,
    template_id = step.session_template_id,
    session_id = session_id or response and (response.session_id or response.session_uuid),
    status = status,
    request = request,
    result = response,
    prompt_summary = bounded_prompt(request.context and request.context.prompt),
    context_id = response and response.context_id,
  }
  table.insert(state.session_requests, session_request)
  run.session_request_id = session_request.id
  run.session_id = session_request.session_id
  push_event(state, "session_template_spawn_requested", run.id, session_request.id, {
    template_id = step.session_template_id,
    session_id = session_request.session_id,
    status = status,
  })
  local err = save_state(state)
  if err then return err end
  if response and response.ok == false then return response end
  return ok({ activation = session_request, run = run })
end

local function record_artifact(arguments)
  arguments = arguments or {}
  local run_id = trim(arguments.run_id)
  if not run_id or run_id == "" then return failure("validation_failed", "run_id is required", { "run_id" }) end
  local state = load_state()
  if not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  local artifact = {
    id = string_arg(arguments, "id") or next_id(state, "artifact"),
    run_id = run_id,
    step_id = string_arg(arguments, "step_id"),
    kind = string_arg(arguments, "kind") or "report",
    summary = string_arg(arguments, "summary"),
    uri = string_arg(arguments, "uri"),
  }
  table.insert(state.artifacts, artifact)
  push_event(state, "artifact_added", run_id, artifact.id)
  local err = save_state(state)
  if err then return err end
  return ok({ artifact = artifact })
end

local function record_question(arguments)
  arguments = arguments or {}
  local run_id = trim(arguments.run_id)
  local question_text = trim(arguments.question)
  if not run_id or run_id == "" then return failure("validation_failed", "run_id is required", { "run_id" }) end
  if not question_text or question_text == "" then return failure("validation_failed", "question is required", { "question" }) end
  local state = load_state()
  if not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  local question = {
    id = string_arg(arguments, "id") or next_id(state, "question"),
    run_id = run_id,
    ticket_id = string_arg(arguments, "ticket_id"),
    step_id = string_arg(arguments, "step_id"),
    status = string_arg(arguments, "status") or "open",
    question = question_text,
  }
  table.insert(state.questions, question)
  push_event(state, "question_asked", run_id, question.id)
  local err = save_state(state)
  if err then return err end
  return ok({ question = question })
end

local function current_context()
  local state = load_state()
  return ok({
    projects = state.projects,
    tickets = state.tickets,
    pipeline_definitions = state.pipeline_definitions,
    runs = state.runs,
    artifacts = state.artifacts,
    questions = state.questions,
    events = state.events,
    session_requests = state.session_requests,
  })
end

local function entities()
  local context = current_context()
  local frames = {}
  local function emit(family, records)
    for _, record in ipairs(records) do
      table.insert(frames, {
        type = "entity_upsert",
        family = "project-pipelines." .. family,
        id = record.id,
        record = record,
      })
    end
  end
  emit("project", context.projects)
  emit("ticket", context.tickets)
  emit("pipeline_definition", context.pipeline_definitions)
  emit("run", context.runs)
  emit("session_request", context.session_requests)
  return ok({ frames = frames })
end

local function text_node(id, value)
  return { type = "text", id = id, props = { value = value }, children = {} }
end

local function bound_list(id, source, empty_title)
  return {
    type = "bind_list",
    id = id,
    props = {
      source = source,
      item_template = {
        type = "row",
        id = id .. "-row",
        props = {
          id = { bind = "@/id" },
          title = { bind = "@/title" },
          subtitle = { bind = "@/status" },
        },
        children = {},
      },
      empty_template = {
        type = "empty_state",
        id = id .. "-empty",
        props = { title = empty_title },
        children = {},
      },
    },
    children = {},
  }
end

local function render_home()
  local context = current_context()
  return {
    type = "screen",
    id = "project-pipelines-home",
    props = {
      title = "Project Pipelines",
      surface_id = "project-pipelines.home",
      state_counts = {
        projects = #context.projects,
        tickets = #context.tickets,
        runs = #context.runs,
        sessions = #context.session_requests,
      },
      bindings = {
        { family = "project-pipelines.project" },
        { family = "project-pipelines.ticket" },
        { family = "project-pipelines.run" },
        { family = "project-pipelines.session_request" },
      },
    },
    children = {
      {
        type = "section",
        id = "project-pipelines-projects",
        props = { title = "Projects" },
        children = { bound_list("project-pipelines-project-list", "project-pipelines.project", "No projects") },
      },
      {
        type = "section",
        id = "project-pipelines-tickets",
        props = { title = "Tickets" },
        children = { bound_list("project-pipelines-ticket-list", "project-pipelines.ticket", "No tickets") },
      },
    },
  }
end

local function render_settings()
  local context = current_context()
  return {
    type = "screen",
    id = "project-pipelines-settings",
    props = {
      title = "Project Pipelines Settings",
      surface_id = "project-pipelines.settings",
      package_name = "project-pipelines",
      storage = "plugin_db",
      state_counts = {
        projects = #context.projects,
        tickets = #context.tickets,
        pipeline_definitions = #context.pipeline_definitions,
        runs = #context.runs,
        sessions = #context.session_requests,
        artifacts = #context.artifacts,
        questions = #context.questions,
      },
    },
    children = {
      text_node("project-pipelines-settings-storage", "Runtime state is persisted by the plugin database capability."),
    },
  }
end

return botster.register({
  tools = {
    { name = "project_pipelines.create_project", description = "Create a Project Pipelines project.", input_schema = object_schema({ name = { type = "string" }, repository = { type = "object" }, repository_id = { type = "string" }, repository_name = { type = "string" }, repository_remote = { type = "string" }, spawn_target_id = { type = "string" }, workspace_id = { type = "string" } }, { "name", "spawn_target_id" }), handler = "create_project", call = create_project },
    { name = "project_pipelines.list_projects", description = "List Project Pipelines projects.", input_schema = empty_schema(), handler = "list_projects", call = list_projects },
    { name = "project_pipelines.show_project", description = "Show one Project Pipelines project.", input_schema = object_schema({ project_id = { type = "string" } }, { "project_id" }), handler = "show_project", call = show_project },
    { name = "project_pipelines.create_ticket", description = "Create a Project Pipelines ticket.", input_schema = object_schema({ project_id = { type = "string" }, workspace_id = { type = "string" }, title = { type = "string" }, description = { type = "string" }, status = { type = "string" }, dependency_ticket_ids = { type = "array" } }, { "project_id", "title" }), handler = "create_ticket", call = create_ticket },
    { name = "project_pipelines.list_tickets", description = "List Project Pipelines tickets.", input_schema = object_schema({ project_id = { type = "string" } }), handler = "list_tickets", call = list_tickets },
    { name = "project_pipelines.show_ticket", description = "Show one Project Pipelines ticket.", input_schema = object_schema({ ticket_id = { type = "string" } }, { "ticket_id" }), handler = "show_ticket", call = show_ticket },
    { name = "project_pipelines.define_pipeline", description = "Define a simple Project Pipelines template.", input_schema = object_schema({ project_id = { type = "string" }, name = { type = "string" }, steps = { type = "array" } }, { "project_id", "name" }), handler = "define_pipeline", call = define_pipeline },
    { name = "project_pipelines.list_pipeline_definitions", description = "List Project Pipelines templates.", input_schema = empty_schema(), handler = "list_pipeline_definitions", call = list_pipeline_definitions },
    { name = "project_pipelines.show_pipeline_definition", description = "Show one Project Pipelines template.", input_schema = object_schema({ pipeline_definition_id = { type = "string" } }, { "pipeline_definition_id" }), handler = "show_pipeline_definition", call = show_pipeline_definition },
    { name = "project_pipelines.record_run", description = "Record a Project Pipelines run skeleton.", input_schema = object_schema({ ticket_id = { type = "string" }, pipeline_definition_id = { type = "string" }, current_step_id = { type = "string" }, status = { type = "string" }, workspace_session_group_id = { type = "string" }, workspace_id = { type = "string" }, repository = { type = "object" }, spawn_target_id = { type = "string" }, branch = { type = "string" }, base_ref = { type = "string" }, worktree = { type = "object" }, worktree_id = { type = "string" } }, { "ticket_id", "pipeline_definition_id" }), handler = "record_run", call = record_run },
    { name = "project_pipelines.activate_step", description = "Activate a run step and spawn a hub session template for PTY-backed steps.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, request_id = { type = "string" }, session_id = { type = "string" }, repository = { type = "object" }, spawn_target_id = { type = "string" }, branch = { type = "string" }, worktree = { type = "object" }, workspace_id = { type = "string" }, prompt = { type = "string" }, cwd = { type = "string" }, environment = { type = "object" }, metadata = { type = "object" } }, { "run_id" }), handler = "activate_step", call = activate_step },
    { name = "project_pipelines.record_artifact", description = "Record a Project Pipelines artifact.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, kind = { type = "string" }, summary = { type = "string" }, uri = { type = "string" } }, { "run_id" }), handler = "record_artifact", call = record_artifact },
    { name = "project_pipelines.record_question", description = "Record a Project Pipelines question.", input_schema = object_schema({ run_id = { type = "string" }, ticket_id = { type = "string" }, step_id = { type = "string" }, status = { type = "string" }, question = { type = "string" } }, { "run_id", "question" }), handler = "record_question", call = record_question },
    { name = "project_pipelines.current_context", description = "Return persisted Project Pipelines context.", input_schema = empty_schema(), handler = "current_context", call = current_context },
    { name = "project_pipelines.entities", description = "Return Project Pipelines entity frames.", input_schema = empty_schema(), handler = "entities", call = entities },
  },
  handlers = {
    { id = "home_surface", kind = "surface_route", descriptor_id = "project-pipelines.home", descriptor = { title = "Project Pipelines", surface_id = "project-pipelines.home" }, call = render_home },
    { id = "settings_surface", kind = "surface_route", descriptor_id = "project-pipelines.settings", descriptor = { title = "Project Pipelines Settings", surface_id = "project-pipelines.settings" }, call = render_settings },
  },
})
