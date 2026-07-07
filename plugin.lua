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

local function diagnostic_failure(code, message, fields)
  local diagnostic = fields or {}
  diagnostic.code = code
  diagnostic.message = message
  return {
    ok = false,
    error = diagnostic,
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
  if mode ~= "pty" and mode ~= "session" and mode ~= "session_template" then return false end
  return step.session_template_id
    or step.session_template_name
    or step.template_name
    or step.session_template_capability
    or step.session_capability
end

local function session_template_selector(step)
  if type(step) ~= "table" then return nil end
  if type(step.session_template_id) == "string" and step.session_template_id ~= "" then
    return { kind = "id", template_id = step.session_template_id, value = step.session_template_id }
  end
  local name = step.session_template_name or step.template_name
  if type(name) == "string" and name ~= "" then
    return { kind = "name", template_name = name, value = name }
  end
  local capability = step.session_template_capability or step.session_capability
  if type(capability) == "string" and capability ~= "" then
    return { kind = "capability", capability = capability, value = capability }
  end
  return nil
end

local function table_contains(values, expected)
  if type(values) ~= "table" then return false end
  for _, value in ipairs(values) do
    if value == expected then return true end
  end
  return false
end

local function first_required_provider_dependency(step)
  local sources = {
    step.required_provider_dependencies,
    step.provider_dependencies,
    step.required_provider_capabilities,
  }
  for _, source in ipairs(sources) do
    if type(source) == "table" then
      for _, dependency in ipairs(source) do
        if type(dependency) == "string" and dependency ~= "" then
          return { dependency = dependency }
        elseif type(dependency) == "table" then
          return {
            dependency = dependency.dependency or dependency.id or dependency.name or dependency.capability,
            provider = dependency.provider,
            capability = dependency.capability,
          }
        end
      end
    end
  end
  return nil
end

local function provider_dependency_available(dependency, capabilities)
  if not dependency or not dependency.dependency then return true end
  local provider_dependencies = capabilities and capabilities.provider_dependencies
  if not provider_dependencies or type(provider_dependencies.check) ~= "function" then return false end
  local ok_response, response = pcall(provider_dependencies.check, dependency)
  if not ok_response or type(response) ~= "table" then return false end
  if response.ok == false then return false end
  if response.available == false or response.status == "blocked" then return false end
  return true
end

local function blocked_diagnostic(code, message, fields)
  local diagnostic = fields or {}
  diagnostic.status = "blocked"
  return diagnostic_failure(code, message, diagnostic)
end

local function resolve_from_list(selector, templates)
  if type(templates) ~= "table" then return nil end
  for _, template in ipairs(templates) do
    if selector.kind == "name" and template.name == selector.template_name then
      return template
    end
    if selector.kind == "capability" then
      if template.capability == selector.capability or table_contains(template.capabilities, selector.capability) then
        return template
      end
    end
  end
  return nil
end

local function resolve_session_template(selector, step, capabilities)
  local dependency = first_required_provider_dependency(step)
  if dependency and not provider_dependency_available(dependency, capabilities) then
    return blocked_diagnostic("provider_dependency_missing", "required provider dependency is unavailable", {
      dependency = dependency.dependency,
      provider = dependency.provider,
      capability = dependency.capability,
      template_selector = selector,
    })
  end

  if selector.kind == "id" then
    return ok({ template_id = selector.template_id, selector = selector })
  end

  local session_templates = capabilities and capabilities.session_templates
  if not session_templates then
    return blocked_diagnostic("session_template_resolution_unavailable", "hub session template resolution capability is unavailable", {
      template_selector = selector,
    })
  end

  if type(session_templates.resolve) == "function" then
    local ok_response, response = pcall(session_templates.resolve, selector)
    if not ok_response then
      return blocked_diagnostic("session_template_resolution_failed", tostring(response), {
        template_selector = selector,
      })
    end
    if type(response) == "table" and response.ok == false then
      local diagnostic = response.error or response.diagnostic or {}
      diagnostic.template_selector = diagnostic.template_selector or selector
      diagnostic.status = diagnostic.status or "blocked"
      return diagnostic_failure(diagnostic.code or "session_template_unavailable", diagnostic.message or "session template selector is unavailable", diagnostic)
    end
    local template_id = response and (response.template_id or response.id)
    if template_id then
      return ok({ template_id = template_id, template = response, selector = selector })
    end
  end

  if type(session_templates.list) == "function" then
    local ok_response, response = pcall(session_templates.list, {})
    if not ok_response then
      return blocked_diagnostic("session_template_resolution_failed", tostring(response), {
        template_selector = selector,
      })
    end
    local templates = response and (response.templates or response)
    local template = resolve_from_list(selector, templates)
    if template and (template.template_id or template.id) then
      return ok({ template_id = template.template_id or template.id, template = template, selector = selector })
    end
    return blocked_diagnostic("session_template_unavailable", "no hub session template matched selector", {
      template_selector = selector,
    })
  end

  return blocked_diagnostic("session_template_resolution_unavailable", "hub session template resolution capability is unavailable", {
    template_selector = selector,
  })
end

local function bounded_prompt(prompt)
  if type(prompt) ~= "string" then return nil end
  if #prompt <= 500 then return prompt end
  return prompt:sub(1, 497) .. "..."
end

local function clean_string_map(values)
  local result = {}
  if type(values) ~= "table" then return result end
  for key, value in pairs(values) do
    if type(key) == "string" and type(value) == "string" then
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
  local metadata = clean_string_map(context_value(arguments, run, ticket, project, step, "metadata"))
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
    environment = clean_string_map(context_value(arguments, run, ticket, project, step, "environment")),
    context = context,
  }
end

local function spawn_session_template(resolved_template, session_id, request)
  local capabilities = botster and botster.capabilities or {}
  local session_templates = capabilities.session_templates
  if not session_templates or type(session_templates.spawn) ~= "function" then
    return failure("session_templates_unavailable", "hub session template spawn capability is unavailable")
  end

  request.template_id = resolved_template.template_id
  request.session_id = session_id
  local ok_response, response = pcall(session_templates.spawn, request)
  if not ok_response then
    return failure("session_template_spawn_failed", tostring(response))
  end
  return response
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
  local selector = session_template_selector(step)
  local resolved = resolve_session_template(selector, step, botster and botster.capabilities or {})
  if resolved and resolved.ok == false then
    local session_request = {
      id = request_id,
      run_id = run.id,
      step_id = step.id,
      ticket_id = ticket.id,
      template_id = selector and selector.template_id,
      template_selector = selector,
      session_id = session_id,
      status = "blocked",
      request = request,
      result = resolved,
      diagnostic = resolved.error,
      prompt_summary = bounded_prompt(request.context and request.context.prompt),
    }
    table.insert(state.session_requests, session_request)
    run.session_request_id = session_request.id
    run.blocked_reason = resolved.error and resolved.error.message
    run.diagnostic = resolved.error
    push_event(state, "session_template_spawn_blocked", run.id, session_request.id, {
      template_selector = selector,
      status = "blocked",
      diagnostic = resolved.error,
    })
    local err = save_state(state)
    if err then return err end
    return resolved
  end

  local response = spawn_session_template(resolved, session_id, request)
  local status = response and response.ok == false and "failed" or "spawn_requested"
  local session_request = {
    id = request_id,
    run_id = run.id,
    step_id = step.id,
    ticket_id = ticket.id,
    template_id = resolved.template_id,
    template_selector = selector,
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
  local event_kind = status == "failed" and "session_template_spawn_failed" or "session_template_spawn_requested"
  push_event(state, event_kind, run.id, session_request.id, {
    template_id = resolved.template_id,
    template_selector = selector,
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

local function ticket_for_run(context, run)
  return find_by_id(context.tickets, run.ticket_id)
end

local function pipeline_for_run(context, run)
  return find_by_id(context.pipeline_definitions, run.pipeline_definition_id)
end

local function status_summary(context)
  local summary = {
    projects = #context.projects,
    tickets = #context.tickets,
    open_tickets = 0,
    active_runs = 0,
    review_runs = 0,
    blocked_sessions = 0,
    failed_sessions = 0,
    open_questions = 0,
    artifacts = #context.artifacts,
  }
  for _, ticket in ipairs(context.tickets) do
    if ticket.status == "open" or ticket.status == nil then
      summary.open_tickets = summary.open_tickets + 1
    end
  end
  for _, run in ipairs(context.runs) do
    if run.status == "active" then
      summary.active_runs = summary.active_runs + 1
    elseif run.status == "ready_for_review" or run.status == "review" or run.status == "ready" then
      summary.review_runs = summary.review_runs + 1
    end
  end
  for _, request in ipairs(context.session_requests) do
    if request.status == "blocked" then
      summary.blocked_sessions = summary.blocked_sessions + 1
    elseif request.status == "failed" then
      summary.failed_sessions = summary.failed_sessions + 1
    end
  end
  for _, question in ipairs(context.questions) do
    if question.status == "open" or question.status == nil then
      summary.open_questions = summary.open_questions + 1
    end
  end
  summary.needs_attention = summary.blocked_sessions + summary.failed_sessions + summary.open_questions
  return summary
end

local function metric_node(id, label, value, tone)
  return {
    type = "metric",
    id = id,
    props = {
      label = label,
      value = value,
      tone = tone or "neutral",
    },
    children = {},
  }
end

local function list_item(id, title, subtitle, status, metadata)
  return {
    type = "list_item",
    id = id,
    props = {
      title = title,
      subtitle = subtitle,
      status = status,
      metadata = metadata or {},
    },
    children = {},
  }
end

local function list_section(id, title, empty_title, items)
  local children = {}
  if #items == 0 then
    children = {
      {
        type = "empty_state",
        id = id .. "-empty",
        props = { title = empty_title },
        children = {},
      },
    }
  else
    children = items
  end
  return {
    type = "section",
    id = id,
    props = { title = title, count = #items },
    children = children,
  }
end

local function attention_items(context)
  local items = {}
  for _, request in ipairs(context.session_requests) do
    if request.status == "blocked" or request.status == "failed" then
      local ticket = find_by_id(context.tickets, request.ticket_id)
      local diagnostic = request.diagnostic or (request.result and request.result.error) or {}
      local status = request.status == "failed" and "failed" or "blocked"
      table.insert(items, list_item(
        "project-pipelines-attention-session-" .. request.id,
        ticket and ticket.title or request.ticket_id or request.id,
        diagnostic.message or request.prompt_summary or "Session request needs attention",
        status,
        {
          run_id = request.run_id,
          step_id = request.step_id,
          request_id = request.id,
          code = diagnostic.code,
          provider = diagnostic.provider,
          dependency = diagnostic.dependency,
        }
      ))
    end
  end
  for _, question in ipairs(context.questions) do
    if question.status == "open" or question.status == nil then
      table.insert(items, list_item(
        "project-pipelines-attention-question-" .. question.id,
        question.question,
        "Open question for run " .. tostring(question.run_id),
        "question",
        {
          run_id = question.run_id,
          ticket_id = question.ticket_id,
          step_id = question.step_id,
          question_id = question.id,
        }
      ))
    end
  end
  return items
end

local function running_items(context)
  local items = {}
  for _, run in ipairs(context.runs) do
    if run.status == "active" then
      local ticket = ticket_for_run(context, run)
      local pipeline = pipeline_for_run(context, run)
      table.insert(items, list_item(
        "project-pipelines-running-" .. run.id,
        ticket and ticket.title or run.id,
        (pipeline and pipeline.name or run.pipeline_definition_id) .. " / " .. tostring(run.current_step_id),
        run.status,
        {
          run_id = run.id,
          ticket_id = run.ticket_id,
          pipeline_definition_id = run.pipeline_definition_id,
          session_id = run.session_id,
          session_request_id = run.session_request_id,
        }
      ))
    end
  end
  return items
end

local function review_items(context)
  local items = {}
  for _, run in ipairs(context.runs) do
    if run.status == "ready_for_review" or run.status == "review" or run.status == "ready" then
      local ticket = ticket_for_run(context, run)
      table.insert(items, list_item(
        "project-pipelines-review-" .. run.id,
        ticket and ticket.title or run.id,
        "Current step " .. tostring(run.current_step_id),
        run.status,
        {
          run_id = run.id,
          ticket_id = run.ticket_id,
          pipeline_definition_id = run.pipeline_definition_id,
        }
      ))
    end
  end
  return items
end

local function provider_dependency_status(context)
  local blocked = {}
  for _, request in ipairs(context.session_requests or {}) do
    local diagnostic = request.diagnostic
    if type(diagnostic) == "table" and diagnostic.code == "provider_dependency_missing" then
      table.insert(blocked, {
        request_id = request.id,
        run_id = request.run_id,
        step_id = request.step_id,
        provider = diagnostic.provider,
        dependency = diagnostic.dependency,
        capability = diagnostic.capability,
        status = "blocked",
        code = diagnostic.code,
        message = diagnostic.message,
      })
    end
  end
  return {
    id = "project-pipelines-provider-dependencies",
    status = #blocked > 0 and "blocked" or "available",
    blocked_count = #blocked,
    blocked = blocked,
  }
end

local function provider_status_text(status)
  if status.blocked_count == 0 then
    return "Provider dependencies are available for recorded session requests."
  end
  local first = status.blocked[1] or {}
  local label = first.dependency or first.capability or "provider dependency"
  if first.provider then label = first.provider .. ":" .. label end
  return "Provider dependency blocked: " .. label
end

local function settings_readiness(context, provider_status)
  local summary = status_summary(context)
  local items = {}
  table.insert(items, list_item(
    "project-pipelines-readiness-storage",
    "Plugin database",
    "Runtime state is persisted by the plugin database capability.",
    "available"
  ))
  table.insert(items, list_item(
    "project-pipelines-readiness-provider-dependencies",
    "Provider dependencies",
    provider_status_text(provider_status),
    provider_status.status
  ))
  local session_status = "available"
  local session_subtitle = "Session template requests are available for recorded runs."
  if summary.failed_sessions > 0 then
    session_status = "failed"
    session_subtitle = tostring(summary.failed_sessions) .. " session request failed."
  elseif summary.blocked_sessions > 0 then
    session_status = "blocked"
    session_subtitle = tostring(summary.blocked_sessions) .. " session request is blocked."
  end
  table.insert(items, list_item(
    "project-pipelines-readiness-session-templates",
    "Session templates",
    session_subtitle,
    session_status
  ))
  return items
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
  local summary = status_summary(context)
  return {
    type = "screen",
    id = "project-pipelines-home",
    props = {
      title = "Project Pipelines",
      surface_id = "project-pipelines.home",
      state_counts = {
        projects = #context.projects,
        tickets = #context.tickets,
        open_tickets = summary.open_tickets,
        runs = #context.runs,
        active_runs = summary.active_runs,
        review_runs = summary.review_runs,
        sessions = #context.session_requests,
        blocked_sessions = summary.blocked_sessions,
        failed_sessions = summary.failed_sessions,
        open_questions = summary.open_questions,
        needs_attention = summary.needs_attention,
        artifacts = summary.artifacts,
      },
      navigation = {
        primary = "pipelines",
        settings_surface_id = "project-pipelines.settings",
      },
      bindings = {
        { family = "project-pipelines.project" },
        { family = "project-pipelines.ticket" },
        { family = "project-pipelines.pipeline_definition" },
        { family = "project-pipelines.run" },
        { family = "project-pipelines.session_request" },
      },
    },
    children = {
      {
        type = "section",
        id = "project-pipelines-command-center",
        props = { title = "Command Center" },
        children = {
          {
            type = "metric_grid",
            id = "project-pipelines-command-center-metrics",
            props = {},
            children = {
              metric_node("project-pipelines-metric-attention", "Needs attention", summary.needs_attention, summary.needs_attention > 0 and "warning" or "neutral"),
              metric_node("project-pipelines-metric-running", "Running", summary.active_runs, "active"),
              metric_node("project-pipelines-metric-review", "Ready for review", summary.review_runs, "review"),
              metric_node("project-pipelines-metric-open-tickets", "Open tickets", summary.open_tickets, "neutral"),
            },
          },
        },
      },
      list_section(
        "project-pipelines-needs-attention",
        "Needs Attention",
        "No blocked sessions, failed requests, or open questions",
        attention_items(context)
      ),
      list_section(
        "project-pipelines-running",
        "Running",
        "No active runs",
        running_items(context)
      ),
      list_section(
        "project-pipelines-ready-for-review",
        "Ready For Review",
        "No runs are waiting for review",
        review_items(context)
      ),
      {
        type = "section",
        id = "project-pipelines-workbench",
        props = { title = "Workbench" },
        children = {
          bound_list("project-pipelines-project-list", "project-pipelines.project", "No projects"),
          bound_list("project-pipelines-ticket-list", "project-pipelines.ticket", "No tickets"),
          bound_list("project-pipelines-run-list", "project-pipelines.run", "No runs"),
          bound_list("project-pipelines-session-request-list", "project-pipelines.session_request", "No session requests"),
        },
      },
      {
        type = "section",
        id = "project-pipelines-create-guidance",
        props = {
          title = "Create And Start Work",
          actions = {
            create_project_tool = "project_pipelines.create_project",
            create_ticket_tool = "project_pipelines.create_ticket",
            define_pipeline_tool = "project_pipelines.define_pipeline",
            record_run_tool = "project_pipelines.record_run",
            activate_step_tool = "project_pipelines.activate_step",
          },
        },
        children = {
          text_node("project-pipelines-create-guidance-summary", "Use the Project Pipelines tools to create projects, tickets, pipeline definitions, runs, and PTY-backed step activations. The app surface reflects persisted state after those actions."),
        },
      },
    },
  }
end

local function render_settings()
  local context = current_context()
  local provider_status = provider_dependency_status(context)
  local summary = status_summary(context)
  return {
    type = "screen",
    id = "project-pipelines-settings",
    props = {
      title = "Project Pipelines Settings",
      surface_id = "project-pipelines.settings",
      package_name = "project-pipelines",
      storage = "plugin_db",
      provider_dependency_status = provider_status,
      state_counts = {
        projects = #context.projects,
        tickets = #context.tickets,
        open_tickets = summary.open_tickets,
        pipeline_definitions = #context.pipeline_definitions,
        runs = #context.runs,
        active_runs = summary.active_runs,
        blocked_sessions = summary.blocked_sessions,
        failed_sessions = summary.failed_sessions,
        sessions = #context.session_requests,
        artifacts = #context.artifacts,
        questions = #context.questions,
        open_questions = summary.open_questions,
      },
    },
    children = {
      {
        type = "section",
        id = "project-pipelines-readiness",
        props = { title = "Readiness" },
        children = settings_readiness(context, provider_status),
      },
      text_node("project-pipelines-settings-storage", "Runtime state is persisted by the plugin database capability."),
      {
        type = "section",
        id = "project-pipelines-provider-dependency-status",
        props = {
          title = "Provider Dependencies",
          status = provider_status.status,
          blocked_count = provider_status.blocked_count,
        },
        children = {
          text_node("project-pipelines-provider-dependency-status-summary", provider_status_text(provider_status)),
        },
      },
      {
        type = "section",
        id = "project-pipelines-settings-defaults",
        props = {
          title = "Defaults",
          fields = {
            "default_spawn_target_id",
            "default_session_template_selector",
            "default_pipeline_mode",
            "workspace_id",
          },
        },
        children = {
          text_node("project-pipelines-settings-defaults-summary", "Package configuration supplies optional defaults for spawn targets, session template selection, pipeline mode, and workspace linkage. Standalone records remain valid without workspace configuration."),
        },
      },
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
