local STORE_SCHEMA_VERSION = 2
local STORE_ROOT = "v2/"
local SOURCE_REVISION = "botster-stack-delivery/2026-07-28.6"
local MAX_STORE_KEYS = 1024
local STORE_KEY_HEADROOM = 64
local MAX_EVENTS = 256
local BLOCKING_FINDING_SEVERITIES = { blocker = true, high = true }
local BLOCKING_FINDING_POLICY = "blocker/high"

local RECORD_FAMILIES = {
  -- Correlation records must become durable before the run records whose
  -- effects they describe. save_state preserves this order.
  "session_requests",
  "advance_requests",
  "projects",
  "tickets",
  "pipeline_definitions",
  "runs",
  "gate_results",
  "reviews",
  "findings",
  "artifacts",
  "checklists",
  "checklist_items",
  "questions",
  "answers",
  "pr_links",
  -- Events are diagnostic consequences and are always written last.
  "events",
}

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

local function deep_equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
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

local function action_result(arguments, state, extra)
  local result = {
    request_id = arguments.request_id,
    surface_id = arguments.surface_id,
    action_id = arguments.action_id,
    node_id = arguments.node_id,
    state = state,
  }
  for key, value in pairs(extra or {}) do
    result[key] = value
  end
  return result
end

local function require_action_request(arguments)
  if type(arguments) ~= "table"
    or type(arguments.request_id) ~= "string"
    or type(arguments.surface_id) ~= "string"
    or type(arguments.action_id) ~= "string"
    or type(arguments.kind) ~= "string"
  then
    error("canonical UiActionRequest envelope is required")
  end
end

local function rejected_action_kind(arguments)
  require_action_request(arguments)
  if arguments.kind == "submit" then return nil end
  local extra = {
    error = "unsupported action kind: " .. arguments.kind,
    form_errors = { "Only submit actions are supported." },
  }
  if type(arguments.values) == "table" then
    extra.normalized_values = copy(arguments.values)
  end
  return action_result(arguments, "rejected", extra)
end

local function action_from_tool(arguments, call, options)
  require_action_request(arguments)
  local kind_rejection = rejected_action_kind(arguments)
  if kind_rejection then return kind_rejection end

  local values = type(arguments.values) == "table" and arguments.values or {}
  local response = call(values)
  if response and response.ok == false then
    local error = response.error or {}
    local fields = {}
    for _, field in ipairs(error.fields or {}) do
      local field_id = options.field_ids and options.field_ids[field] or field
      fields[field_id] = { error.message or "Action rejected" }
    end
    local state = error.code == "validation_failed" and "rejected" or "error"
    local extra = {
      error = error.message or "Action rejected",
      form_errors = { error.message or "Action rejected" },
      payload = response,
      normalized_values = copy(values),
    }
    if next(fields) ~= nil then extra.field_errors = fields end
    return action_result(arguments, state, extra)
  end
  return action_result(arguments, "accepted", {
    normalized_values = copy(values),
    presentation = options.presentation,
    replacement = options.replacement(response),
    payload = response,
  })
end

local function action_ack(arguments, payload, presentation)
  require_action_request(arguments)
  local kind_rejection = rejected_action_kind(arguments)
  if kind_rejection then return kind_rejection end
  return action_result(arguments, "accepted", {
    payload = payload,
    presentation = presentation,
  })
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
    schema_version = STORE_SCHEMA_VERSION,
    counters = {
      project = 0,
      ticket = 0,
      pipeline_definition = 0,
      run = 0,
      gate_result = 0,
      review = 0,
      finding = 0,
      artifact = 0,
      checklist = 0,
      checklist_item = 0,
      question = 0,
      answer = 0,
      pr_link = 0,
      event = 0,
      session_request = 0,
      advance_request = 0,
    },
    projects = {},
    tickets = {},
    pipeline_definitions = {},
    runs = {},
    gate_results = {},
    reviews = {},
    findings = {},
    artifacts = {},
    checklists = {},
    checklist_items = {},
    questions = {},
    answers = {},
    pr_links = {},
    events = {},
    session_requests = {},
    advance_requests = {},
    _original_counters = {},
    _originals = {},
    _positions = {},
    _revisions = {},
    _counter_revision = 0,
    _store_key_count = 0,
  }
end

local function store()
  return botster and botster.capabilities and botster.capabilities.plugin_db
end

local function record_key(family, id)
  return STORE_ROOT .. family .. "/" .. id
end

local function record_payload(response)
  if type(response) ~= "table" or type(response.record) ~= "table" then return nil end
  return type(response.record.payload) == "table" and response.record.payload or nil
end

local RECORD_REQUIRED_FIELDS = {
  projects = { "id", "name", "repository", "spawn_target_id" },
  tickets = { "id", "project_id", "title", "status" },
  pipeline_definitions = { "id", "name", "steps" },
  runs = { "id", "ticket_id", "pipeline_definition_id", "current_step_id", "status" },
  gate_results = { "id", "run_id", "step_id", "gate_id", "status" },
  reviews = { "id", "run_id", "step_id", "verdict" },
  findings = { "id", "run_id", "review_id", "severity", "status" },
  artifacts = { "id", "run_id", "kind" },
  checklists = { "id", "run_id", "name" },
  checklist_items = { "id", "checklist_id", "text", "status" },
  questions = { "id", "run_id", "question", "status" },
  answers = { "id", "question_id", "answer" },
  pr_links = { "id", "run_id", "url" },
  events = { "id", "kind" },
  session_requests = { "id", "run_id", "step_id", "status" },
  advance_requests = { "id", "request_id", "run_id", "previous_step_id", "step_id", "status", "result" },
}

local function validate_record(family, payload)
  if type(payload) ~= "table" then return false, "payload must be an object" end
  for _, field in ipairs(RECORD_REQUIRED_FIELDS[family] or { "id" }) do
    local value = payload[field]
    if value == nil or (type(value) == "string" and value == "") then
      return false, "missing required field " .. field
    end
  end
  if type(payload.id) ~= "string" then return false, "id must be a string" end
  return true
end

local function validate_counters(counters)
  if type(counters) ~= "table" then return false end
  for key, value in pairs(counters) do
    if type(key) ~= "string" or type(value) ~= "number" or value < 0 then return false end
  end
  return true
end

local function list_entries(response)
  if type(response) ~= "table" then return {} end
  return type(response.entries) == "table" and response.entries or {}
end

local function load_state()
  local plugin_db = store()
  local state = default_state()
  if not plugin_db or type(plugin_db.get) ~= "function" or type(plugin_db.list) ~= "function" then
    return state
  end

  state._store_key_count = #list_entries(plugin_db.list({ prefix = STORE_ROOT }))
  local counter_response = plugin_db.get({ key = STORE_ROOT .. "meta/counters" })
  local counters = record_payload(counter_response)
  if counters then
    if not validate_counters(counters) then error("invalid project-pipelines counters payload") end
    state.counters = counters
    state._counter_revision = counter_response.record.revision or 0
  end
  state._original_counters = copy(state.counters)
  for _, family in ipairs(RECORD_FAMILIES) do
    state._originals[family] = {}
    state._positions[family] = {}
    state._revisions[family] = {}
    local listed = plugin_db.list({ prefix = STORE_ROOT .. family .. "/" })
    for _, entry in ipairs(list_entries(listed)) do
      if type(entry.key) == "string" then
        local response = plugin_db.get({ key = entry.key })
        local payload = record_payload(response)
        if payload then
          local valid, reason = validate_record(family, payload)
          if not valid then error("invalid " .. family .. " record " .. entry.key .. ": " .. reason) end
          state._positions[family][payload.id] = payload._store_position
          state._revisions[family][payload.id] = response.record.revision or entry.revision or 0
          table.insert(state[family], payload)
        end
      end
    end
    table.sort(state[family], function(left, right)
      local left_position = left._store_position
      local right_position = right._store_position
      if type(left_position) == "number" and type(right_position) == "number" then
        return left_position < right_position
      end
      return tostring(left.id) < tostring(right.id)
    end)
    for _, record in ipairs(state[family]) do
      record._store_position = nil
      state._originals[family][record.id] = copy(record)
    end
  end
  return state
end

local function save_state(state)
  local plugin_db = store()
  if not plugin_db or type(plugin_db.set) ~= "function" then
    return failure("persist_failed", "plugin_db capability is unavailable")
  end

  local deleted_keys = {}
  local new_key_count = 0
  for _, family in ipairs(RECORD_FAMILIES) do
    local current = {}
    for _, record in ipairs(state[family] or {}) do current[record.id] = true end
    for id in pairs(state._originals and state._originals[family] or {}) do
      if not current[id] then table.insert(deleted_keys, record_key(family, id)) end
    end
    for _, record in ipairs(state[family] or {}) do
      if not (state._originals and state._originals[family] and state._originals[family][record.id]) then
        new_key_count = new_key_count + 1
      end
    end
  end
  if state._counter_revision == 0 and not deep_equal(state.counters, state._original_counters or {}) then
    new_key_count = new_key_count + 1
  end
  local projected_keys = (state._store_key_count or 0) - #deleted_keys + new_key_count
  if projected_keys > MAX_STORE_KEYS - STORE_KEY_HEADROOM then
    return failure("store_capacity_exhausted", "project-pipelines store has reached its reserved key ceiling", {
      projected_keys = projected_keys,
      maximum_keys = MAX_STORE_KEYS,
      reserved_headroom = STORE_KEY_HEADROOM,
    })
  end

  for _, key in ipairs(deleted_keys) do
    local deleted, delete_error = pcall(plugin_db.delete, { key = key })
    if not deleted then
      return failure("persist_failed", "plugin_db delete failed", { key = key, reason = tostring(delete_error) })
    end
    state._store_key_count = state._store_key_count - 1
  end

  local function persist(args)
    local written, response = pcall(plugin_db.set, args)
    if not written then
      return nil, failure("persist_failed", "plugin_db write failed", { key = args.key, reason = tostring(response) })
    end
    return response, nil
  end

  -- Counters are reserved first so retries cannot reuse identifiers.
  if not deep_equal(state.counters, state._original_counters or {}) then
    local response, err = persist({
      key = STORE_ROOT .. "meta/counters",
      schema_version = STORE_SCHEMA_VERSION,
      payload = state.counters,
      expected_revision = state._counter_revision or 0,
    })
    if err then return err end
    state._counter_revision = response and response.record and response.record.revision
      or (state._counter_revision or 0) + 1
    state._original_counters = copy(state.counters)
    if state._counter_revision == 1 then state._store_key_count = state._store_key_count + 1 end
  end
  for _, family in ipairs(RECORD_FAMILIES) do
    for position, record in ipairs(state[family] or {}) do
      local valid, reason = validate_record(family, record)
      if not valid then
        return failure("invalid_record", "invalid " .. family .. " record: " .. reason, { family = family, id = record.id })
      end
      local original = state._originals and state._originals[family] and state._originals[family][record.id]
      if not original or not deep_equal(record, original) then
        local payload = copy(record)
        payload._store_position = state._positions
          and state._positions[family]
          and state._positions[family][record.id]
          or position
        local revision = state._revisions and state._revisions[family] and state._revisions[family][record.id] or 0
        local response, err = persist({
          key = record_key(family, record.id),
          schema_version = STORE_SCHEMA_VERSION,
          payload = payload,
          expected_revision = revision,
        })
        if err then return err end
        state._revisions[family][record.id] = response and response.record and response.record.revision or revision + 1
        state._originals[family][record.id] = copy(record)
        state._positions[family][record.id] = payload._store_position
        if revision == 0 then state._store_key_count = state._store_key_count + 1 end
      end
    end
  end
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
  while #state.events > MAX_EVENTS do table.remove(state.events, 1) end
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

local REPOSITORY_ROUTING = {
  { slug = "botster-core", playbook = "[[botster-core-playbook]]" },
  { slug = "botster-hub", playbook = "[[botster-hub-playbook]]" },
  { slug = "botster-hub-client", playbook = "[[botster-hub-client-playbook]]" },
  { slug = "botster-web", playbook = "[[botster-web-playbook]]" },
  { slug = "botster-tui", playbook = "[[botster-tui-playbook]]" },
  { slug = "botster-tui-kit", playbook = "[[botster-tui-kit-playbook]]" },
  { slug = "botster-workspaces", playbook = "[[botster-workspaces-playbook]]" },
  { slug = "botster-terminal-ghostty", playbook = "[[botster-terminal-ghostty-playbook]]" },
}

local function project_pipelines_path(path)
  if type(path) ~= "string" then return false end
  return path == "plugin.lua"
    or path == "botster-package.json"
    or path:match("^project[_%-]pipelines/")
    or path:match("^fixtures/project_pipelines/")
end

local function resolve_repository_playbook(arguments)
  arguments = arguments or {}
  local repository = trim(arguments.repository)
    or trim(arguments.repository_name)
    or trim(arguments.name)
  local path = trim(arguments.path)
  local matches = {}
  if repository then
    local slug = repository:match("([^/]+)$") or repository
    for _, route in ipairs(REPOSITORY_ROUTING) do
      if route.slug == slug then table.insert(matches, route.playbook) end
    end
    if slug == "botster-project-pipelines" then
      table.insert(matches, "[[project-pipelines-playbook]]")
    end
  end
  if project_pipelines_path(path) then
    table.insert(matches, "[[project-pipelines-playbook]]")
  end
  local unique = {}
  local charters = {}
  for _, charter in ipairs(matches) do
    if not unique[charter] then
      unique[charter] = true
      table.insert(charters, charter)
    end
  end
  if #charters == 0 then
    return failure("routing_question_required", "repository does not resolve to a supported ownership charter")
  end
  if #charters > 1 then
    return failure("routing_question_required", "repository routing resolved to multiple ownership charters")
  end
  return ok({ repository = repository, path = path, playbook = charters[1] })
end

local function routing_prompt()
  local routes = {}
  for _, route in ipairs(REPOSITORY_ROUTING) do
    table.insert(routes, route.slug .. " -> " .. route.playbook)
  end
  table.insert(routes, "Project Pipelines package/plugin paths -> [[project-pipelines-playbook]]")
  return "Resolve target_id to the authoritative repository before acting. Load exactly one repository charter: "
    .. table.concat(routes, "; ")
    .. ". Zero or multiple matches require a routing question; never substitute a generic charter or load every charter."
end

local function sourced_step(id, name, position, agent_name, role_prompt, options)
  options = options or {}
  return {
    id = id,
    name = name,
    position = position,
    kind = options.kind or "pty",
    session_template_capability = options.session_template_capability or "botster.pipeline.agent",
    agent_name = agent_name,
    prompt = role_prompt .. "\n\n" .. routing_prompt(),
    allows_open_ticket_dependencies = options.allows_open_ticket_dependencies == true,
    gates = options.gates or {},
    next_step_id = options.next_step_id,
    source_revision = SOURCE_REVISION,
  }
end

local function botster_stack_delivery_source()
  return {
    id = "botster_stack_delivery",
    source_id = "botster_stack_delivery",
    source_revision = SOURCE_REVISION,
    source_authority = "trybotster/botster-project-pipelines:plugin.lua",
    name = "Botster Stack Delivery",
    merge_policy = "pr",
    steps = {
      sourced_step("botster_stack_plan", "Plan", 1, "codex", "Create a repository-specific implementation plan and persist a reviewable plan artifact.", {
        allows_open_ticket_dependencies = true,
        next_step_id = "botster_stack_plan_review",
        gates = {
          { id = "plan_artifact", required = true, prompt = "Persist the approved plan and vault workflow evidence." },
        },
      }),
      sourced_step("botster_stack_plan_review", "Plan Review", 2, "claude", "Independently verify repository routing, ownership, risks, and executable acceptance checks.", {
        allows_open_ticket_dependencies = true,
        next_step_id = "botster_stack_implement",
        gates = {
          {
            id = "plan_review",
            required = true,
            prompt = "Submit an approved plan review with no open " .. BLOCKING_FINDING_POLICY .. " findings.",
          },
        },
      }),
      sourced_step("botster_stack_implement", "Implement", 3, "codex", "Implement the approved plan in the routed run worktree and prove the production entry point.", {
        next_step_id = "botster_stack_review",
        gates = {
          { id = "implementation", required = true, prompt = "Provide committed diff evidence, tests, a report artifact, and a linked PR." },
        },
      }),
      sourced_step("botster_stack_review", "Review", 4, "claude", "Review correctness, regressions, architecture fit, tests, docs, dead paths, and hidden assumptions.", {
        next_step_id = "botster_stack_verify",
        gates = {
          {
            id = "review",
            required = true,
            prompt = "Submit an approved review with no open " .. BLOCKING_FINDING_POLICY .. " findings.",
          },
        },
      }),
      sourced_step("botster_stack_verify", "Verify", 5, "codex", "Rerun live-worktree evidence and recheck every resolved blocker against observed state.", {
        next_step_id = "botster_stack_merge",
        gates = {
          { id = "verification", required = true, prompt = "Attach fresh live-worktree command evidence for tests and resolved findings." },
        },
      }),
      sourced_step("botster_stack_merge", "Merge", 6, "codex", "Confirm the linked pull request is merge-ready and record the terminal disposition.", {
        kind = "manual",
        gates = {
          { id = "merge_ready", required = true, prompt = "Confirm the linked PR is ready and all required gates are durable." },
        },
      }),
    },
  }
end

local function same_source_revision(pipeline)
  return pipeline
    and pipeline.source_id == "botster_stack_delivery"
    and pipeline.source_revision == SOURCE_REVISION
end

local function reconcile_sourced_pipeline()
  local state = load_state()
  local source = botster_stack_delivery_source()
  local existing = find_by_id(state.pipeline_definitions, source.id)
  if same_source_revision(existing) then return existing end

  if existing then
    local selected_agents = {}
    for _, step in ipairs(array(existing.steps)) do
      if type(step.agent_name) == "string" and step.agent_name ~= "" then
        selected_agents[step.id] = step.agent_name
      end
    end
    for _, step in ipairs(source.steps) do
      step.agent_name = selected_agents[step.id] or step.agent_name
    end
    for key in pairs(existing) do existing[key] = nil end
    for key, value in pairs(source) do existing[key] = copy(value) end
    push_event(state, "pipeline_source_reconciled", nil, source.id, { source_revision = SOURCE_REVISION })
  else
    table.insert(state.pipeline_definitions, source)
    push_event(state, "pipeline_source_initialized", nil, source.id, { source_revision = SOURCE_REVISION })
  end
  local err = save_state(state)
  if err then error(err.error and err.error.message or "failed to reconcile sourced pipeline") end
  return source
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

local function resolve_session_template(selector, step, capabilities, target_id)
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
    local ok_response, response = pcall(session_templates.list, { target_id = target_id })
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
  local prompt = context_value(arguments, run, ticket, project, step, "prompt")
  local metadata = clean_string_map(context_value(arguments, run, ticket, project, step, "metadata"))
  metadata.owner_plugin = metadata.owner_plugin or "project-pipelines"
  metadata.surface = metadata.surface or "project-pipelines"
  metadata.run_id = run.id
  metadata.step_id = step.id
  metadata.ticket_id = ticket.id

  local context = {
    branch_name = context_value(arguments, run, ticket, project, step, "branch") or run.branch,
    prompt = prompt,
    ticket_id = ticket.id,
    workspace_id = context_value(arguments, run, ticket, project, step, "workspace_id"),
    metadata = metadata,
  }
  if context.workspace_id == nil then context.workspace_id = project.workspace_id or ticket.workspace_id end

  return {
    target_id = context_value(arguments, run, ticket, project, step, "spawn_target_id") or project.spawn_target_id,
    environment = clean_string_map(context_value(arguments, run, ticket, project, step, "environment")),
    context = context,
  }
end

local function spawn_session_template(resolved_template, request)
  local capabilities = botster and botster.capabilities or {}
  local session_templates = capabilities.session_templates
  if not session_templates then
    return failure("session_templates_unavailable", "hub session template spawn capability is unavailable")
  end

  if type(session_templates.ensure_worktree_and_spawn) ~= "function" then
    return failure("session_templates_unavailable", "managed session template spawn capability is unavailable")
  end
  local operation = session_templates.ensure_worktree_and_spawn
  local dispatched_request = {
    template_id = resolved_template.template_id,
    target_id = request.target_id,
    branch = request.context and request.context.branch_name,
    environment = request.environment,
    context = {
      prompt = request.context and request.context.prompt,
      ticket_id = request.context and request.context.ticket_id,
      workspace_id = request.context and request.context.workspace_id,
      metadata = request.context and request.context.metadata,
    },
  }
  local ok_response, response = pcall(operation, dispatched_request)
  if not ok_response then
    return failure("session_template_spawn_failed", tostring(response)), dispatched_request
  end
  if type(response) == "table" and response.ok == true and type(response.result) == "table" then
    return response.result, dispatched_request
  end
  return response, dispatched_request
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

local function add_ticket_dependency(arguments)
  arguments = arguments or {}
  local ticket_id = string_arg(arguments, "ticket_id")
  local dependency_ticket_id = string_arg(arguments, "dependency_ticket_id")
  if not ticket_id then return failure("validation_failed", "ticket_id is required", { "ticket_id" }) end
  if not dependency_ticket_id then return failure("validation_failed", "dependency_ticket_id is required", { "dependency_ticket_id" }) end
  if ticket_id == dependency_ticket_id then
    return failure("validation_failed", "ticket cannot depend on itself", { "dependency_ticket_id" })
  end
  local state = load_state()
  local ticket = find_by_id(state.tickets, ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. ticket_id) end
  if not find_by_id(state.tickets, dependency_ticket_id) then
    return failure("not_found", "dependency ticket not found: " .. dependency_ticket_id)
  end
  ticket.dependency_ticket_ids = array(ticket.dependency_ticket_ids)
  if table_contains(ticket.dependency_ticket_ids, dependency_ticket_id) then
    return ok({ ticket = ticket })
  end
  table.insert(ticket.dependency_ticket_ids, dependency_ticket_id)
  push_event(state, "ticket_dependency_added", nil, ticket.id, { dependency_ticket_id = dependency_ticket_id })
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function remove_ticket_dependency(arguments)
  arguments = arguments or {}
  local ticket_id = string_arg(arguments, "ticket_id")
  local dependency_ticket_id = string_arg(arguments, "dependency_ticket_id")
  if not ticket_id then return failure("validation_failed", "ticket_id is required", { "ticket_id" }) end
  if not dependency_ticket_id then return failure("validation_failed", "dependency_ticket_id is required", { "dependency_ticket_id" }) end
  local state = load_state()
  local ticket = find_by_id(state.tickets, ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. ticket_id) end
  local dependencies = {}
  local removed = false
  for _, id in ipairs(array(ticket.dependency_ticket_ids)) do
    if id == dependency_ticket_id then
      removed = true
    else
      table.insert(dependencies, id)
    end
  end
  if not removed then return ok({ ticket = ticket }) end
  ticket.dependency_ticket_ids = dependencies
  push_event(state, "ticket_dependency_removed", nil, ticket.id, { dependency_ticket_id = dependency_ticket_id })
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function update_ticket_status(arguments)
  arguments = arguments or {}
  local ticket_id = string_arg(arguments, "ticket_id")
  local status = string_arg(arguments, "status")
  if not ticket_id then return failure("validation_failed", "ticket_id is required", { "ticket_id" }) end
  if status ~= "open" and status ~= "closed" then
    return failure("validation_failed", "status must be open or closed", { "status" })
  end
  local state = load_state()
  local ticket = find_by_id(state.tickets, ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. ticket_id) end
  if ticket.status == status then return ok({ ticket = ticket }) end
  ticket.status = status
  push_event(state, "ticket_status_updated", nil, ticket.id, { status = status })
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function unmet_ticket_dependencies(state, ticket)
  local unmet = {}
  for _, dependency_ticket_id in ipairs(array(ticket and ticket.dependency_ticket_ids)) do
    local dependency_ticket = find_by_id(state.tickets, dependency_ticket_id)
    if not dependency_ticket or dependency_ticket.status ~= "closed" then
      table.insert(unmet, {
        dependency_ticket_id = dependency_ticket_id,
        status = dependency_ticket and (dependency_ticket.status or "open") or "missing",
      })
    end
  end
  return unmet
end

local function existing_spawn_activation(state, run, step)
  if run.current_step_id ~= step.id then return nil end
  local request = find_by_id(state.session_requests, run.session_request_id)
  if request and request.run_id == run.id and request.step_id == step.id and request.status == "spawn_requested" then
    return request
  end
  return nil
end

local function session_request_for(state, request_id, run, step)
  if not request_id then return nil end
  local request = find_by_id(state.session_requests, request_id)
  if request and request.run_id == run.id and request.step_id == step.id then return request end
  return nil
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

  if step.allows_open_ticket_dependencies ~= true then
    local unmet_dependencies = unmet_ticket_dependencies(state, ticket)
    if #unmet_dependencies > 0 then
      local diagnostic = {
        status = "blocked",
        code = "ticket_dependencies_unmet",
        message = "ticket has open blocking dependencies",
        ticket_id = ticket.id,
        step_id = step.id,
        unmet_dependencies = unmet_dependencies,
      }
      run.blocked_transition = copy(diagnostic)
      push_event(state, "ticket_dependencies_blocked", run.id, step.id, copy(diagnostic))
      local err = save_state(state)
      if err then return err end
      return diagnostic_failure(diagnostic.code, diagnostic.message, diagnostic)
    end
  end

  local blocked_transition_cleared = run.blocked_transition ~= nil
  run.blocked_transition = nil

  local request_id = string_arg(arguments, "request_id")
  local existing_activation = session_request_for(state, request_id, run, step)
    or existing_spawn_activation(state, run, step)
  if existing_activation then
    if blocked_transition_cleared then
      local err = save_state(state)
      if err then return err end
    end
    if existing_activation.status == "spawning" then
      return diagnostic_failure(
        "activation_outcome_unknown",
        "managed spawn was dispatched but its final result was not durably recorded; refusing to spawn again",
        { request_id = existing_activation.id, run_id = run.id, step_id = step.id }
      )
    end
    return ok({ activation = existing_activation, run = run })
  end

  if not step_uses_session_template(step) then
    run.current_step_id = step.id
    push_event(state, "step_started", run.id, step.id)
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

  request_id = request_id or next_id(state, "session_request")
  local request = build_session_template_request(arguments, run, ticket, project, step)
  if not request.target_id or request.target_id == "" then
    return failure("validation_failed", "spawn target is required for session-template activation", { "target_id" })
  end
  local selector = session_template_selector(step)
  if string_arg(arguments, "session_template_id") then
    selector = {
      kind = "id",
      template_id = string_arg(arguments, "session_template_id"),
      value = string_arg(arguments, "session_template_id"),
    }
  end
  local resolved = resolve_session_template(selector, step, botster and botster.capabilities or {}, request.target_id)
  if resolved and resolved.ok == false then
    local session_request = {
      id = request_id,
      run_id = run.id,
      step_id = step.id,
      ticket_id = ticket.id,
      template_id = selector and selector.template_id,
      template_selector = selector,
      session_id = nil,
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

  local session_request = {
    id = request_id,
    run_id = run.id,
    step_id = step.id,
    ticket_id = ticket.id,
    template_id = resolved.template_id,
    template_selector = selector,
    status = "spawning",
    request = request,
    prompt_summary = bounded_prompt(request.context and request.context.prompt),
  }
  table.insert(state.session_requests, session_request)
  local pending_error = save_state(state)
  if pending_error then return pending_error end

  local response, dispatched_request = spawn_session_template(resolved, request)
  state = load_state()
  run = find_by_id(state.runs, run_id)
  session_request = find_by_id(state.session_requests, request_id)
  if not run or not session_request then
    return failure("persist_failed", "durable spawn correlation record disappeared")
  end
  request = dispatched_request or request
  local status = response and response.ok == false and "failed" or "spawn_requested"
  session_request.session_id = response and (response.session_id or response.session_uuid)
  session_request.status = status
  session_request.request = request
  session_request.result = response
  session_request.prompt_summary = bounded_prompt(request.context and request.context.prompt)
  session_request.context_id = response and response.context_id
  run.current_step_id = step.id
  run.session_request_id = session_request.id
  run.session_id = session_request.session_id
  push_event(state, "step_started", run.id, step.id)
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
    payload = type(arguments.payload) == "table" and copy(arguments.payload) or nil,
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
    blocking = arguments.blocking == true,
    asked_by = string_arg(arguments, "asked_by"),
    question = question_text,
  }
  table.insert(state.questions, question)
  push_event(state, "question_asked", run_id, question.id)
  local err = save_state(state)
  if err then return err end
  return ok({ question = question })
end

local function answer_question(arguments)
  arguments = arguments or {}
  local question_id = string_arg(arguments, "question_id")
  local text = trim(arguments.answer)
  if not question_id then return failure("validation_failed", "question_id is required", { "question_id" }) end
  if not text or text == "" then return failure("validation_failed", "answer is required", { "answer" }) end
  local state = load_state()
  local question = find_by_id(state.questions, question_id)
  if not question then return failure("not_found", "question not found: " .. question_id) end
  if question.status == "answered" then
    for _, existing in ipairs(state.answers) do
      if existing.question_id == question_id then return ok({ answer = existing, question = question }) end
    end
  end
  local answer = {
    id = string_arg(arguments, "id") or next_id(state, "answer"),
    question_id = question_id,
    run_id = question.run_id,
    answered_by = string_arg(arguments, "answered_by"),
    answer = text,
  }
  table.insert(state.answers, answer)
  question.status = "answered"
  question.answer_id = answer.id
  push_event(state, "question_answered", question.run_id, question.id, { answer_id = answer.id })
  local err = save_state(state)
  if err then return err end
  return ok({ answer = answer, question = question })
end

local function submit_gate(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  local step_id = string_arg(arguments, "step_id")
  local gate_id = string_arg(arguments, "gate_id")
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  if not step_id then return failure("validation_failed", "step_id is required", { "step_id" }) end
  if not gate_id then return failure("validation_failed", "gate_id is required", { "gate_id" }) end
  local state = load_state()
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
  local step = find_pipeline_step(pipeline, step_id)
  if not step then return failure("not_found", "step not found: " .. step_id) end
  local gate
  for _, candidate in ipairs(array(step.gates)) do
    if candidate.id == gate_id then gate = candidate end
  end
  if not gate then return failure("not_found", "gate not found: " .. gate_id) end
  local result
  for _, candidate in ipairs(state.gate_results) do
    if candidate.run_id == run_id and candidate.step_id == step_id and candidate.gate_id == gate_id then
      result = candidate
    end
  end
  if not result then
    result = {
      id = string_arg(arguments, "id") or next_id(state, "gate_result"),
      run_id = run_id,
      step_id = step_id,
      gate_id = gate_id,
    }
    table.insert(state.gate_results, result)
  end
  result.status = string_arg(arguments, "status") or "passed"
  result.summary = string_arg(arguments, "summary")
  result.evidence = type(arguments.evidence) == "table" and copy(arguments.evidence) or {}
  push_event(state, "gate_submitted", run_id, result.id, {
    step_id = step_id,
    gate_id = gate_id,
    status = result.status,
  })
  local err = save_state(state)
  if err then return err end
  return ok({ gate_result = result })
end

local function submit_review(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  local step_id = string_arg(arguments, "step_id")
  local verdict = string_arg(arguments, "verdict")
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  if not step_id then return failure("validation_failed", "step_id is required", { "step_id" }) end
  if verdict ~= "approved" and verdict ~= "changes_required" and verdict ~= "blocked" then
    return failure("validation_failed", "verdict must be approved, changes_required, or blocked", { "verdict" })
  end
  local state = load_state()
  if not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  local review = {
    id = string_arg(arguments, "id") or next_id(state, "review"),
    run_id = run_id,
    step_id = step_id,
    verdict = verdict,
    summary = string_arg(arguments, "summary"),
  }
  table.insert(state.reviews, review)
  for _, input in ipairs(array(arguments.findings)) do
    local finding = {
      id = input.id or next_id(state, "finding"),
      review_id = review.id,
      run_id = run_id,
      step_id = step_id,
      severity = input.severity or "medium",
      status = input.status or "open",
      title = input.title or "Review finding",
      details = input.details,
      file = input.file,
      line = input.line,
      suggested_fix = input.suggested_fix,
    }
    table.insert(state.findings, finding)
    push_event(state, "finding_opened", run_id, finding.id, { review_id = review.id })
  end
  push_event(state, "review_submitted", run_id, review.id, { verdict = verdict })
  local err = save_state(state)
  if err then return err end
  return ok({ review = review })
end

local function resolve_finding(arguments)
  arguments = arguments or {}
  local finding_id = string_arg(arguments, "finding_id")
  if not finding_id then return failure("validation_failed", "finding_id is required", { "finding_id" }) end
  local state = load_state()
  local finding = find_by_id(state.findings, finding_id)
  if not finding then return failure("not_found", "finding not found: " .. finding_id) end
  finding.status = "resolved"
  finding.resolution = string_arg(arguments, "resolution")
  push_event(state, "finding_resolved", finding.run_id, finding.id)
  local err = save_state(state)
  if err then return err end
  return ok({ finding = finding })
end

local function create_checklist(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  local name = trim(arguments.name)
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local state = load_state()
  if not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  local checklist = {
    id = string_arg(arguments, "id") or next_id(state, "checklist"),
    run_id = run_id,
    step_id = string_arg(arguments, "step_id"),
    source = string_arg(arguments, "source") or "pipeline",
    name = name,
    description = string_arg(arguments, "description"),
  }
  table.insert(state.checklists, checklist)
  push_event(state, "checklist_created", run_id, checklist.id)
  local err = save_state(state)
  if err then return err end
  return ok({ checklist = checklist })
end

local function add_checklist_item(arguments)
  arguments = arguments or {}
  local checklist_id = string_arg(arguments, "checklist_id")
  local text = trim(arguments.text)
  if not checklist_id then return failure("validation_failed", "checklist_id is required", { "checklist_id" }) end
  if not text or text == "" then return failure("validation_failed", "text is required", { "text" }) end
  local state = load_state()
  local checklist = find_by_id(state.checklists, checklist_id)
  if not checklist then return failure("not_found", "checklist not found: " .. checklist_id) end
  local item = {
    id = string_arg(arguments, "id") or next_id(state, "checklist_item"),
    checklist_id = checklist_id,
    run_id = checklist.run_id,
    text = text,
    status = string_arg(arguments, "status") or "completed",
    evidence = type(arguments.evidence) == "table" and copy(arguments.evidence) or nil,
  }
  table.insert(state.checklist_items, item)
  push_event(state, "checklist_item_added", checklist.run_id, item.id, { checklist_id = checklist_id })
  local err = save_state(state)
  if err then return err end
  return ok({ checklist_item = item })
end

local function link_pr(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  local url = trim(arguments.url)
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  if not url or url == "" then return failure("validation_failed", "url is required", { "url" }) end
  local state = load_state()
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  for _, existing in ipairs(state.pr_links) do
    if existing.run_id == run_id and existing.url == url then return ok({ pr_link = existing }) end
  end
  local link = {
    id = string_arg(arguments, "id") or next_id(state, "pr_link"),
    run_id = run_id,
    ticket_id = run.ticket_id,
    url = url,
    provider = string_arg(arguments, "provider") or "github",
    status = string_arg(arguments, "status") or "open",
  }
  table.insert(state.pr_links, link)
  push_event(state, "pr_linked", run_id, link.id)
  local err = save_state(state)
  if err then return err end
  return ok({ pr_link = link })
end

local function gate_result_for(state, run_id, step_id, gate_id)
  local selected
  for _, result in ipairs(state.gate_results) do
    if result.run_id == run_id and result.step_id == step_id and result.gate_id == gate_id then
      selected = result
    end
  end
  return selected
end

local function transition_blockers(state, run, pipeline, step)
  local blockers = {}
  for _, gate in ipairs(array(step.gates)) do
    local result = gate_result_for(state, run.id, step.id, gate.id)
    if gate.required ~= false and (not result or result.status ~= "passed") then
      table.insert(blockers, { kind = "gate", gate_id = gate.id })
    end
  end
  local latest_review
  for _, review in ipairs(state.reviews) do
    if review.run_id == run.id and review.step_id == step.id then latest_review = review end
  end
  if latest_review and latest_review.verdict ~= "approved" then
    table.insert(blockers, { kind = "review", review_id = latest_review.id, verdict = latest_review.verdict })
  end
  for _, finding in ipairs(state.findings) do
    if finding.run_id == run.id
      and finding.status ~= "resolved"
      and finding.status ~= "waived"
      and BLOCKING_FINDING_SEVERITIES[finding.severity] == true
    then
      table.insert(blockers, { kind = "finding", finding_id = finding.id, severity = finding.severity })
    end
  end
  if step.id == "botster_stack_implement" then
    local result = gate_result_for(state, run.id, step.id, "implementation")
    local evidence = result and result.evidence or {}
    if type(evidence.commit_sha) ~= "string" or evidence.commit_sha == "" then
      table.insert(blockers, { kind = "implementation_commit" })
    end
    if type(evidence.diff_against_base) ~= "string" or evidence.diff_against_base == "" then
      table.insert(blockers, { kind = "implementation_diff" })
    end
    local linked = false
    for _, pr_link in ipairs(state.pr_links) do
      if pr_link.run_id == run.id and type(pr_link.url) == "string" and pr_link.url ~= "" then linked = true end
    end
    if pipeline.merge_policy == "pr" and not linked then
      table.insert(blockers, { kind = "pr_link" })
    end
  end
  if step.id == "botster_stack_verify" then
    local result = gate_result_for(state, run.id, step.id, "verification")
    local verified = result and result.evidence and result.evidence.resolved_finding_ids or {}
    for _, finding in ipairs(state.findings) do
      if finding.run_id == run.id
        and finding.status == "resolved"
        and (finding.severity == "blocker" or finding.severity == "high")
        and not table_contains(verified, finding.id)
      then
        table.insert(blockers, { kind = "resolved_finding_evidence", finding_id = finding.id })
      end
    end
  end
  return blockers
end

local function request_step_advance(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  local state = load_state()
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  local request_id = string_arg(arguments, "request_id")
  if request_id then
    for _, request in ipairs(state.advance_requests) do
      if request.request_id == request_id then
        if request.run_id ~= run.id then
          return failure("request_id_conflict", "advance request_id belongs to another run")
        end
        if run.current_step_id == request.previous_step_id then
          run.current_step_id = request.step_id
          run.status = "active"
          push_event(state, "step_advanced", run.id, request.step_id, {
            from_step_id = request.previous_step_id,
            request_id = request.request_id,
            recovered = true,
          })
          request.status = "applied"
          local recovered_error = save_state(state)
          if recovered_error then return recovered_error end
        elseif run.current_step_id ~= request.step_id then
          return failure("advance_recovery_conflict", "run no longer matches the durable advance request")
        elseif request.status ~= "applied" then
          request.status = "applied"
          local recovered_error = save_state(state)
          if recovered_error then return recovered_error end
        end
        return copy(request.result)
      end
    end
  end
  local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. run.pipeline_definition_id) end
  local current_step = find_pipeline_step(pipeline, run.current_step_id)
  if not current_step then return failure("not_found", "current step not found: " .. tostring(run.current_step_id)) end
  local next_step_id = string_arg(arguments, "next_step_id") or current_step.next_step_id
  if not next_step_id then return failure("terminal_step", "current step has no next step") end
  local next_step = find_pipeline_step(pipeline, next_step_id)
  if not next_step then return failure("not_found", "next step not found: " .. next_step_id) end
  local blockers = transition_blockers(state, run, pipeline, current_step)
  local ticket = find_by_id(state.tickets, run.ticket_id)
  if next_step.allows_open_ticket_dependencies ~= true then
    for _, dependency in ipairs(unmet_ticket_dependencies(state, ticket)) do
      table.insert(blockers, { kind = "ticket_dependency", dependency = dependency })
    end
  end
  if #blockers > 0 then
    return diagnostic_failure("transition_blocked", "step transition has unmet requirements", {
      status = "blocked",
      run_id = run.id,
      step_id = current_step.id,
      next_step_id = next_step_id,
      blockers = blockers,
    })
  end
  local response_run = copy(run)
  response_run.current_step_id = next_step_id
  response_run.status = "active"
  local response = ok({ run = response_run, previous_step_id = current_step.id, step_id = next_step_id })
  local advance_request
  if request_id then
    advance_request = {
      id = next_id(state, "advance_request"),
      request_id = request_id,
      run_id = run.id,
      previous_step_id = current_step.id,
      step_id = next_step_id,
      status = "pending",
      result = copy(response),
    }
    table.insert(state.advance_requests, advance_request)
    local correlation_error = save_state(state)
    if correlation_error then return correlation_error end
    state = load_state()
    run = find_by_id(state.runs, run_id)
    advance_request = find_by_id(state.advance_requests, advance_request.id)
  end
  run.current_step_id = next_step_id
  run.status = "active"
  push_event(state, "step_advanced", run.id, next_step_id, {
    from_step_id = current_step.id,
    request_id = request_id,
  })
  if advance_request then advance_request.status = "applied" end
  local err = save_state(state)
  if err then return err end
  return response
end

local function records_for_run(records, run_id)
  if not run_id then return records end
  local selected = {}
  for _, record in ipairs(records) do
    if record.run_id == run_id or record.id == run_id then table.insert(selected, record) end
  end
  return selected
end

local function current_context(arguments)
  arguments = arguments or {}
  local state = load_state()
  local run_id = string_arg(arguments, "run_id")
  return ok({
    projects = state.projects,
    tickets = state.tickets,
    pipeline_definitions = state.pipeline_definitions,
    runs = records_for_run(state.runs, run_id),
    gate_results = records_for_run(state.gate_results, run_id),
    reviews = records_for_run(state.reviews, run_id),
    findings = records_for_run(state.findings, run_id),
    artifacts = records_for_run(state.artifacts, run_id),
    checklists = records_for_run(state.checklists, run_id),
    checklist_items = records_for_run(state.checklist_items, run_id),
    questions = records_for_run(state.questions, run_id),
    answers = records_for_run(state.answers, run_id),
    pr_links = records_for_run(state.pr_links, run_id),
    events = records_for_run(state.events, run_id),
    session_requests = records_for_run(state.session_requests, run_id),
    source_revision = SOURCE_REVISION,
    source_authority = "trybotster/botster-project-pipelines:plugin.lua",
  })
end

local function open_dialog_action(arguments, key)
  require_action_request(arguments)
  local kind_rejection = rejected_action_kind(arguments)
  if kind_rejection then return kind_rejection end
  local payload = type(arguments.payload) == "table" and arguments.payload or {}
  if payload.intent ~= "open_dialog" then return nil end
  return action_result(arguments, "accepted", {
    presentation = {
      { kind = "set", key = key, value = true },
    },
  })
end

local function create_ticket_action(arguments)
  local open_result = open_dialog_action(arguments, "project-pipelines.create-ticket-dialog")
  if open_result then return open_result end
  return action_from_tool(arguments, create_ticket, {
    field_ids = {
      project_id = "project-pipelines-create-ticket-project-id",
      title = "project-pipelines-create-ticket-title",
    },
    presentation = {
      { kind = "clear", key = "project-pipelines.create-ticket-dialog" },
    },
    replacement = function(response)
      return {
        type = "text",
        id = "project-pipelines-created-ticket",
        props = { text = "Created ticket " .. tostring(response.ticket.title) },
      }
    end,
  })
end

local function record_run_action(arguments)
  local open_result = open_dialog_action(arguments, "project-pipelines.record-run-dialog")
  if open_result then return open_result end
  return action_from_tool(arguments, record_run, {
    field_ids = {
      ticket_id = "project-pipelines-record-run-ticket-id",
      pipeline_definition_id = "project-pipelines-record-run-pipeline-id",
    },
    presentation = {
      { kind = "clear", key = "project-pipelines.record-run-dialog" },
    },
    replacement = function(response)
      return {
        type = "text",
        id = "project-pipelines-recorded-run",
        props = { text = "Recorded run " .. tostring(response.run.id) },
      }
    end,
  })
end

local function activate_step_action(arguments)
  local open_result = open_dialog_action(arguments, "project-pipelines.activate-step-dialog")
  if open_result then return open_result end
  return action_from_tool(arguments, activate_step, {
    field_ids = {
      run_id = "project-pipelines-action-run-id",
      step_id = "project-pipelines-action-step-id",
    },
    presentation = {
      { kind = "clear", key = "project-pipelines.activate-step-dialog" },
    },
    replacement = function(response)
      local activation = response.activation or {}
      return {
        type = "status_badge",
        id = "project-pipelines-activated-step",
        props = {
          label = "Step " .. tostring(activation.status or "activated"),
          status = activation.status or "active",
          tone = "success",
        },
      }
    end,
  })
end

local function filter_action(arguments)
  require_action_request(arguments)
  local kind_rejection = rejected_action_kind(arguments)
  if kind_rejection then return kind_rejection end
  local payload = type(arguments.payload) == "table" and arguments.payload or {}
  if type(payload.status) ~= "string" or payload.status == "" then
    return action_result(arguments, "rejected", {
      error = "filter status is required",
      form_errors = { "Filter status is required." },
    })
  end
  return action_ack(arguments, {
    filter = payload.status,
  }, {
    { kind = "set", key = "project-pipelines.filter", value = payload.status },
  })
end

local function select_row_action(arguments)
  require_action_request(arguments)
  local kind_rejection = rejected_action_kind(arguments)
  if kind_rejection then return kind_rejection end
  local payload = type(arguments.payload) == "table" and arguments.payload or {}
  local row_id = payload.row_id or payload.id or payload.value
  if type(row_id) ~= "string" or row_id == "" then
    return action_result(arguments, "rejected", {
      error = "selected row id is required",
      form_errors = { "Selected row id is required." },
    })
  end
  return action_ack(arguments, {
    row_id = row_id,
  }, {
    { kind = "set", key = "selected-workspace", value = row_id },
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
  emit("gate_result", context.gate_results)
  emit("review", context.reviews)
  emit("finding", context.findings)
  emit("artifact", context.artifacts)
  emit("checklist", context.checklists)
  emit("question", context.questions)
  emit("pr_link", context.pr_links)
  emit("session_request", context.session_requests)
  return ok({ frames = frames })
end

local function text_node(id, value)
  return { type = "text", id = id, props = { text = value } }
end

local function badge_node(id, label, tone)
  return {
    type = "badge",
    id = id,
    props = { label = label, tone = tone or "default" },
  }
end

local function status_badge_node(id, label, status, tone)
  return {
    type = "status_badge",
    id = id,
    props = { label = label, status = status or label, tone = tone or "default" },
  }
end

local function panel_node(id, title, children, tone)
  local props = { title = title }
  if tone then props.tone = tone end
  local node = { type = "panel", id = id, props = props }
  if children and #children > 0 then node.children = children end
  return node
end

local function inline_node(id, children)
  local node = {
    type = "inline",
    id = id,
    props = { gap = "sm", align = "center" },
  }
  if children and #children > 0 then node.children = children end
  return node
end

local function list_node(id, children)
  local node = {
    type = "list",
    id = id,
    props = { aria_label = id },
  }
  if children and #children > 0 then node.children = children end
  return node
end

local function list_item(id, title, subtitle, status)
  local tone = status == "failed" and "danger" or status == "blocked" and "warning" or "muted"
  return {
    type = "list_item",
    id = id,
    props = { value = id },
    slots = {
      title = { text_node(id .. "-title", title) },
      subtitle = {
        inline_node(id .. "-subtitle", {
          text_node(id .. "-subtitle-text", subtitle),
          status_badge_node(id .. "-status", status or "unknown", status or "unknown", tone),
        }),
      },
    },
  }
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
    blocked_transitions = 0,
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
    if type(run.blocked_transition) == "table" then
      summary.blocked_transitions = summary.blocked_transitions + 1
    end
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
  summary.needs_attention = summary.blocked_transitions + summary.blocked_sessions + summary.failed_sessions + summary.open_questions
  return summary
end

local function metric_node(id, label, value, tone, caption, status)
  local props = {
    label = label,
    value = tostring(value),
    tone = tone or "default",
  }
  if caption then props.caption = caption end
  if status then props.status = status end
  return { type = "metric", id = id, props = props }
end

local function metric_grid_node(id, children)
  return {
    type = "metric_grid",
    id = id,
    props = { density = "compact", variant = "subtle", compact = true },
    children = children,
  }
end

local function button_node(id, label, action_id, arguments, tone)
  local props = {
    label = label,
    action = { id = action_id, payload = arguments or {} },
  }
  if tone then props.tone = tone end
  return { type = "button", id = id, props = props }
end

local function toolbar_node(id)
  return {
    type = "toolbar",
    id = id,
    props = { label = "Workbench actions", density = "compact", variant = "plain" },
    slots = {
      commands = {
        button_node("project-pipelines-toolbar-create-ticket", "Create ticket", "project_pipelines.create_ticket", { intent = "open_dialog" }),
        button_node("project-pipelines-toolbar-record-run", "Record run", "project_pipelines.record_run", { intent = "open_dialog" }),
      },
      filters = {
        button_node("project-pipelines-toolbar-filter-attention", "Needs attention", "project_pipelines.filter", { status = "attention" }, "warning"),
        button_node("project-pipelines-toolbar-filter-running", "Running", "project_pipelines.filter", { status = "active" }, "accent"),
        button_node("project-pipelines-toolbar-filter-review", "Review", "project_pipelines.filter", { status = "review" }, "success"),
      },
      actions = {
        button_node("project-pipelines-toolbar-activate-step", "Activate step", "project_pipelines.activate_step", { intent = "open_dialog" }),
      },
    },
  }
end

local function section_node(id, title, description, children, tone)
  local props = { title = title }
  if description then props.description = description end
  if tone then props.tone = tone end
  local node = { type = "section", id = id, props = props }
  if children and #children > 0 then node.children = children end
  return node
end

local function list_section(id, title, empty_title, items)
  local children = items
  if #items == 0 then
    children = {
      { type = "empty_state", id = id .. "-empty", props = { title = empty_title, description = "No matching workflow records are currently persisted." } },
    }
  end
  return section_node(id, title, nil, { list_node(id .. "-list", children) })
end

local function attention_items(context)
  local items = {}
  for _, run in ipairs(context.runs) do
    local blocked = run.blocked_transition
    if type(blocked) == "table" and blocked.code == "ticket_dependencies_unmet" then
      local ticket = ticket_for_run(context, run)
      local names = {}
      for _, dependency in ipairs(array(blocked.unmet_dependencies)) do
        local dependency_ticket = find_by_id(context.tickets, dependency.dependency_ticket_id)
        table.insert(names, dependency_ticket and dependency_ticket.title or dependency.dependency_ticket_id)
      end
      table.insert(items, list_item(
        "project-pipelines-attention-dependencies-" .. run.id,
        ticket and ticket.title or run.ticket_id,
        "Blocked before " .. tostring(blocked.step_id) .. " by " .. table.concat(names, ", "),
        "blocked"
      ))
    end
  end
  for _, request in ipairs(context.session_requests) do
    if request.status == "blocked" or request.status == "failed" then
      local ticket = find_by_id(context.tickets, request.ticket_id)
      local diagnostic = request.diagnostic or (request.result and request.result.error) or {}
      local status = request.status == "failed" and "failed" or "blocked"
      table.insert(items, list_item(
        "project-pipelines-attention-session-" .. request.id,
        ticket and ticket.title or request.ticket_id or request.id,
        diagnostic.message or request.prompt_summary or "Session request needs attention",
        status
      ))
    end
  end
  for _, question in ipairs(context.questions) do
    if question.status == "open" or question.status == nil then
      table.insert(items, list_item(
        "project-pipelines-attention-question-" .. question.id,
        question.question,
        "Open question for run " .. tostring(question.run_id),
        "question"
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
      local blocked = run.blocked_transition
      local step_id = type(blocked) == "table" and blocked.step_id or run.current_step_id
      table.insert(items, list_item(
        "project-pipelines-running-" .. run.id,
        ticket and ticket.title or run.id,
        (pipeline and pipeline.name or run.pipeline_definition_id) .. " / " .. tostring(step_id),
        type(blocked) == "table" and "blocked" or run.status
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
        run.status
      ))
    end
  end
  return items
end

local bound_list

local function run_status_label(run)
  if type(run.blocked_transition) == "table" then return "blocked" end
  return run.status or "unknown"
end

local function run_status_tone(status)
  if status == "failed" then return "danger" end
  if status == "blocked" then return "warning" end
  if status == "ready_for_review" or status == "review" or status == "ready" then return "success" end
  if status == "active" then return "accent" end
  return "muted"
end

local function project_rows(context)
  local rows = {}
  for _, project in ipairs(context.projects) do
    local row = {
      id = project.id,
      cells = {
        name = project.name,
        mode = project.mode or "standalone",
        spawn_target = project.spawn_target_id or "",
      },
    }
    if type(project.workspace_id) == "string" and project.workspace_id ~= "" then
      row.action = {
        id = "project_pipelines.select_row",
        payload = { row_id = project.workspace_id },
      }
    end
    table.insert(rows, row)
  end
  return rows
end

local function ticket_rows(context)
  local rows = {}
  for _, ticket in ipairs(context.tickets) do
    local project = find_by_id(context.projects, ticket.project_id)
    table.insert(rows, {
      id = ticket.id,
      cells = {
        title = ticket.title,
        project = project and project.name or ticket.project_id,
        status = ticket.status or "open",
      },
    })
  end
  return rows
end

local function run_rows(context)
  local rows = {}
  for _, run in ipairs(context.runs) do
    local ticket = ticket_for_run(context, run)
    local pipeline = pipeline_for_run(context, run)
    local blocked = run.blocked_transition
    local blockers = {}
    for _, dependency in ipairs(type(blocked) == "table" and array(blocked.unmet_dependencies) or {}) do
      local dependency_ticket = find_by_id(context.tickets, dependency.dependency_ticket_id)
      table.insert(blockers, dependency_ticket and dependency_ticket.title or dependency.dependency_ticket_id)
    end
    table.insert(rows, {
      id = run.id,
      cells = {
        ticket = ticket and ticket.title or run.ticket_id,
        pipeline = pipeline and pipeline.name or run.pipeline_definition_id,
        step = type(blocked) == "table" and blocked.step_id or run.current_step_id or "",
        blocker = table.concat(blockers, ", "),
        status = run_status_label(run),
      },
    })
  end
  return rows
end

local function session_request_rows(context)
  local rows = {}
  for _, request in ipairs(context.session_requests) do
    table.insert(rows, {
      id = request.id,
      cells = {
        request = request.id,
        run = request.run_id or "",
        step = request.step_id or "",
        status = request.status or "unknown",
      },
    })
  end
  return rows
end

local function table_node(id, columns, rows, empty_title)
  local props = {
    columns = columns,
    selection = { mode = "single" },
    empty_state = {
      type = "empty_state",
      id = id .. "-empty",
      props = { title = empty_title },
    },
  }
  if rows and #rows > 0 then props.rows = rows end
  return {
    type = "table",
    id = id,
    props = props,
  }
end

local function action_feedback_form()
  return {
    type = "form",
    id = "project-pipelines-action-feedback",
    props = {
      action = { id = "project_pipelines.activate_step" },
      submit_label = "Activate step",
    },
    children = {
      {
        type = "form_section",
        id = "project-pipelines-action-feedback-section",
        props = {
          title = "Action Feedback",
          description = "Activate a run step or inspect persisted action results.",
        },
        children = {
          {
            type = "form_field",
            id = "project-pipelines-action-run-id",
            props = {
              schema = {
                kind = "text",
                name = "run_id",
                label = "Run id",
                required = true,
              },
            },
          },
          {
            type = "form_field",
            id = "project-pipelines-action-step-id",
            props = {
              schema = {
                kind = "text",
                name = "step_id",
                label = "Step id",
                required = true,
              },
            },
          },
          button_node("project-pipelines-action-submit", "Activate step", "project_pipelines.activate_step", {}, "accent"),
        },
      },
    },
  }
end

local function text_input_node(id, name, label, required)
  return {
    type = "text_input",
    id = id,
    props = {
      name = name,
      label = label,
      required = required == true,
    },
  }
end

local function dialog_form(id, action_id, submit_label, children)
  return {
    type = "form",
    id = id,
    props = {
      action = { id = action_id },
      submit_label = submit_label,
    },
    children = children,
  }
end

local function presentation_dialog(key, id, title, form)
  return {
    ["$kind"] = "presentation_if",
    predicate = { kind = "present", key = key },
    node = {
      type = "dialog",
      id = id,
      props = {
        title = title,
        presentation = "auto",
      },
      slots = { body = { form } },
    },
  }
end

local function workbench_dialogs(context)
  local children = {
    presentation_dialog(
      "project-pipelines.create-ticket-dialog",
      "project-pipelines-create-ticket-dialog",
      "Create ticket",
      dialog_form(
        "project-pipelines-create-ticket-form",
        "project_pipelines.create_ticket",
        "Create ticket",
        {
          text_input_node("project-pipelines-create-ticket-project-id", "project_id", "Project id", true),
          text_input_node("project-pipelines-create-ticket-title", "title", "Title", true),
        }
      )
    ),
    presentation_dialog(
      "project-pipelines.record-run-dialog",
      "project-pipelines-record-run-dialog",
      "Record run",
      dialog_form(
        "project-pipelines-record-run-form",
        "project_pipelines.record_run",
        "Record run",
        {
          text_input_node("project-pipelines-record-run-ticket-id", "ticket_id", "Ticket id", true),
          text_input_node("project-pipelines-record-run-pipeline-id", "pipeline_definition_id", "Pipeline definition id", true),
        }
      )
    ),
    presentation_dialog(
      "project-pipelines.activate-step-dialog",
      "project-pipelines-activate-step-dialog",
      "Activate step",
      action_feedback_form()
    ),
  }
  for _, project in ipairs(context.projects) do
    if type(project.workspace_id) == "string" and project.workspace_id ~= "" then
      table.insert(children, {
        ["$kind"] = "presentation_if",
        predicate = {
          kind = "equals",
          key = "selected-workspace",
          value = project.workspace_id,
        },
        node = text_node(
          "project-pipelines-selected-workspace-" .. project.id,
          "Workspace " .. project.name .. " selected"
        ),
      })
    end
  end
  return children
end

local function drilldown_tables(context)
  return section_node("project-pipelines-workbench", "Project/Ticket/Run Drilldown", "Current persisted workflow records with selectable rows.", {
    table_node("project-pipelines-project-table", {
      { id = "name", label = "Project" },
      { id = "mode", label = "Mode" },
      { id = "spawn_target", label = "Spawn target" },
    }, project_rows(context), "No projects"),
    table_node("project-pipelines-ticket-table", {
      { id = "title", label = "Ticket" },
      { id = "project", label = "Project" },
      { id = "status", label = "Status" },
    }, ticket_rows(context), "No tickets"),
    table_node("project-pipelines-run-table", {
      { id = "ticket", label = "Ticket" },
      { id = "pipeline", label = "Pipeline" },
      { id = "step", label = "Step" },
      { id = "blocker", label = "Blocking prerequisite" },
      { id = "status", label = "Status" },
    }, run_rows(context), "No runs"),
    table_node("project-pipelines-session-request-table", {
      { id = "request", label = "Request" },
      { id = "run", label = "Run" },
      { id = "step", label = "Step" },
      { id = "status", label = "Status" },
    }, session_request_rows(context), "No session requests"),
  })
end

local function entity_stream_section()
  return section_node("project-pipelines-entity-streams", "Entity Streams", "Live client rows bind to plugin-owned entity families.", {
    list_node("project-pipelines-workbench-lists", {
      bound_list("project-pipelines-project-list", "project-pipelines.project", "No projects"),
      bound_list("project-pipelines-ticket-list", "project-pipelines.ticket", "No tickets"),
      bound_list("project-pipelines-run-list", "project-pipelines.run", "No runs"),
      bound_list("project-pipelines-session-request-list", "project-pipelines.session_request", "No session requests"),
    }),
  })
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

function bound_list(id, source, empty_title)
  return {
    ["$kind"] = "bind_list",
    source = "/" .. source,
    item_template = {
      type = "list_item",
      id = id .. "-row",
      props = { value = { ["$bind"] = "@/id" } },
      slots = {
        title = {
          { type = "text", id = id .. "-row-title", props = { text = { ["$bind"] = "@/title" } } },
        },
        subtitle = {
          { type = "text", id = id .. "-row-subtitle", props = { text = { ["$bind"] = "@/status" } } },
        },
      },
    },
    empty_template = {
      type = "empty_state",
      id = id .. "-empty",
      props = { title = empty_title },
    },
  }
end

local function render_home()
  local context = current_context()
  local summary = status_summary(context)
  local children = {
      panel_node("project-pipelines-command-center", "Command Center", {
        toolbar_node("project-pipelines-workbench-toolbar"),
        metric_grid_node("project-pipelines-command-center-metrics", {
          metric_node("project-pipelines-metric-attention", "Needs attention", summary.needs_attention, summary.needs_attention > 0 and "warning" or "default", "Blocked, failed, or open questions", summary.needs_attention > 0 and "needs_attention" or "clear"),
          metric_node("project-pipelines-metric-running", "Running", summary.active_runs, "accent", "Active pipeline runs", "active"),
          metric_node("project-pipelines-metric-review", "Ready for review", summary.review_runs, "success", "Review or merge queue", "ready"),
          metric_node("project-pipelines-metric-open-tickets", "Open tickets", summary.open_tickets, "muted", "Open ticket records", "open"),
        }),
      }),
      list_section(
        "project-pipelines-needs-attention",
        "Needs Attention",
        "No blocked transitions, blocked sessions, failed requests, or open questions",
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
      drilldown_tables(context),
      entity_stream_section(),
      section_node("project-pipelines-create-guidance", "Create And Start Work", nil, {
        text_node("project-pipelines-create-guidance-summary", "Use the Project Pipelines tools to create projects, tickets, pipeline definitions, runs, and PTY-backed step activations. The app surface reflects persisted state after those actions."),
        list_node("project-pipelines-create-guidance-actions", {
          list_item("project-pipelines-create-project-action", "Create project", "project_pipelines.create_project", "tool"),
          list_item("project-pipelines-create-ticket-action", "Create ticket", "project_pipelines.create_ticket", "tool"),
          list_item("project-pipelines-define-pipeline-action", "Define pipeline", "project_pipelines.define_pipeline", "tool"),
          list_item("project-pipelines-record-run-action", "Record run", "project_pipelines.record_run", "tool"),
          list_item("project-pipelines-activate-step-action", "Activate step", "project_pipelines.activate_step", "tool"),
        }),
      }),
    }
  for _, dialog in ipairs(workbench_dialogs(context)) do
    table.insert(children, dialog)
  end
  return panel_node("project-pipelines-home", "Project Pipelines", children)
end

local function render_settings()
  local context = current_context()
  local provider_status = provider_dependency_status(context)
  local summary = status_summary(context)
  return panel_node("project-pipelines-settings", "Project Pipelines Settings", {
      inline_node("project-pipelines-settings-counts", {
        metric_node("project-pipelines-settings-count-projects", "Projects", #context.projects, "muted"),
        metric_node("project-pipelines-settings-count-tickets", "Tickets", #context.tickets, "muted"),
        metric_node("project-pipelines-settings-count-runs", "Runs", #context.runs, "muted"),
        metric_node("project-pipelines-settings-count-sessions", "Session requests", #context.session_requests, "muted"),
        metric_node("project-pipelines-settings-count-open-questions", "Open questions", summary.open_questions, summary.open_questions > 0 and "warning" or "muted"),
      }),
      panel_node("project-pipelines-readiness", "Readiness", {
        list_node("project-pipelines-readiness-list", settings_readiness(context, provider_status)),
      }),
      text_node("project-pipelines-settings-storage", "Runtime state is persisted by the plugin database capability."),
      panel_node("project-pipelines-provider-dependency-status", "Provider Dependencies", {
        text_node("project-pipelines-provider-dependency-status-summary", provider_status_text(provider_status)),
        badge_node("project-pipelines-provider-dependency-status-badge", provider_status.status .. ": " .. tostring(provider_status.blocked_count), provider_status.status == "blocked" and "warning" or "success"),
      }),
      panel_node("project-pipelines-settings-defaults", "Defaults", {
        text_node("project-pipelines-settings-defaults-summary", "Package configuration supplies optional defaults for spawn targets, session template selection, pipeline mode, and workspace linkage. Standalone records remain valid without workspace configuration."),
        list_node("project-pipelines-settings-default-fields", {
          list_item("project-pipelines-settings-default-spawn-target", "Default spawn target", "default_spawn_target_id", "config"),
          list_item("project-pipelines-settings-default-session-template", "Default session template", "default_session_template_selector", "config"),
          list_item("project-pipelines-settings-default-pipeline-mode", "Default pipeline mode", "default_pipeline_mode", "config"),
          list_item("project-pipelines-settings-workspace-id", "Workspace id", "workspace_id", "config"),
        }),
      }),
    })
end

reconcile_sourced_pipeline()

return botster.register({
  tools = {
    { name = "project_pipelines.create_project", description = "Create a Project Pipelines project.", input_schema = object_schema({ name = { type = "string" }, repository = { type = "object" }, repository_id = { type = "string" }, repository_name = { type = "string" }, repository_remote = { type = "string" }, spawn_target_id = { type = "string" }, workspace_id = { type = "string" } }, { "name", "spawn_target_id" }), handler = "create_project", call = create_project },
    { name = "project_pipelines.list_projects", description = "List Project Pipelines projects.", input_schema = empty_schema(), handler = "list_projects", call = list_projects },
    { name = "project_pipelines.show_project", description = "Show one Project Pipelines project.", input_schema = object_schema({ project_id = { type = "string" } }, { "project_id" }), handler = "show_project", call = show_project },
    { name = "project_pipelines.create_ticket", description = "Create a Project Pipelines ticket.", input_schema = object_schema({ project_id = { type = "string" }, workspace_id = { type = "string" }, title = { type = "string" }, description = { type = "string" }, status = { type = "string" }, dependency_ticket_ids = { type = "array" } }, { "project_id", "title" }), handler = "create_ticket", call = create_ticket },
    { name = "project_pipelines.list_tickets", description = "List Project Pipelines tickets.", input_schema = object_schema({ project_id = { type = "string" } }), handler = "list_tickets", call = list_tickets },
    { name = "project_pipelines.show_ticket", description = "Show one Project Pipelines ticket.", input_schema = object_schema({ ticket_id = { type = "string" } }, { "ticket_id" }), handler = "show_ticket", call = show_ticket },
    { name = "project_pipelines.add_ticket_dependency", description = "Add a blocking dependency to a Project Pipelines ticket.", input_schema = object_schema({ ticket_id = { type = "string" }, dependency_ticket_id = { type = "string" } }, { "ticket_id", "dependency_ticket_id" }), handler = "add_ticket_dependency", call = add_ticket_dependency },
    { name = "project_pipelines.remove_ticket_dependency", description = "Remove a blocking dependency from a Project Pipelines ticket.", input_schema = object_schema({ ticket_id = { type = "string" }, dependency_ticket_id = { type = "string" } }, { "ticket_id", "dependency_ticket_id" }), handler = "remove_ticket_dependency", call = remove_ticket_dependency },
    { name = "project_pipelines.update_ticket_status", description = "Update a Project Pipelines ticket status.", input_schema = object_schema({ ticket_id = { type = "string" }, status = { type = "string", enum = { "open", "closed" } } }, { "ticket_id", "status" }), handler = "update_ticket_status", call = update_ticket_status },
    { name = "project_pipelines.define_pipeline", description = "Define a simple Project Pipelines template.", input_schema = object_schema({ project_id = { type = "string" }, name = { type = "string" }, steps = { type = "array" } }, { "project_id", "name" }), handler = "define_pipeline", call = define_pipeline },
    { name = "project_pipelines.list_pipeline_definitions", description = "List Project Pipelines templates.", input_schema = empty_schema(), handler = "list_pipeline_definitions", call = list_pipeline_definitions },
    { name = "project_pipelines.show_pipeline_definition", description = "Show one Project Pipelines template.", input_schema = object_schema({ pipeline_definition_id = { type = "string" } }, { "pipeline_definition_id" }), handler = "show_pipeline_definition", call = show_pipeline_definition },
    { name = "project_pipelines.record_run", description = "Record a Project Pipelines run skeleton.", input_schema = object_schema({ ticket_id = { type = "string" }, pipeline_definition_id = { type = "string" }, current_step_id = { type = "string" }, status = { type = "string" }, workspace_session_group_id = { type = "string" }, workspace_id = { type = "string" }, repository = { type = "object" }, spawn_target_id = { type = "string" }, branch = { type = "string" }, base_ref = { type = "string" }, worktree = { type = "object" }, worktree_id = { type = "string" } }, { "ticket_id", "pipeline_definition_id" }), handler = "record_run", call = record_run },
    { name = "project_pipelines.activate_step", description = "Activate a run step and atomically ensure a managed Git worktree and Hub session template.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, request_id = { type = "string" }, session_template_id = { type = "string" }, repository = { type = "object" }, spawn_target_id = { type = "string" }, branch = { type = "string" }, worktree = { type = "object" }, workspace_id = { type = "string" }, prompt = { type = "string" }, environment = { type = "object" }, metadata = { type = "object" } }, { "run_id" }), handler = "activate_step", call = activate_step },
    { name = "project_pipelines.submit_gate", description = "Persist gate evidence for one run step.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, gate_id = { type = "string" }, status = { type = "string" }, summary = { type = "string" }, evidence = { type = "object" } }, { "run_id", "step_id", "gate_id" }), handler = "submit_gate", call = submit_gate },
    { name = "project_pipelines.submit_review", description = "Persist a review and its findings.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, verdict = { type = "string" }, summary = { type = "string" }, findings = { type = "array" } }, { "run_id", "step_id", "verdict" }), handler = "submit_review", call = submit_review },
    { name = "project_pipelines.resolve_finding", description = "Resolve one durable review finding.", input_schema = object_schema({ finding_id = { type = "string" }, resolution = { type = "string" } }, { "finding_id" }), handler = "resolve_finding", call = resolve_finding },
    { name = "project_pipelines.record_artifact", description = "Record a Project Pipelines artifact.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, kind = { type = "string" }, summary = { type = "string" }, uri = { type = "string" }, payload = { type = "object" } }, { "run_id" }), handler = "record_artifact", call = record_artifact },
    { name = "project_pipelines.create_checklist", description = "Create a durable pipeline or vault checklist.", input_schema = object_schema({ run_id = { type = "string" }, step_id = { type = "string" }, source = { type = "string" }, name = { type = "string" }, description = { type = "string" } }, { "run_id", "name" }), handler = "create_checklist", call = create_checklist },
    { name = "project_pipelines.add_checklist_item", description = "Add evidence to a durable checklist.", input_schema = object_schema({ checklist_id = { type = "string" }, text = { type = "string" }, status = { type = "string" }, evidence = { type = "object" } }, { "checklist_id", "text" }), handler = "add_checklist_item", call = add_checklist_item },
    { name = "project_pipelines.record_question", description = "Record a Project Pipelines question.", input_schema = object_schema({ run_id = { type = "string" }, ticket_id = { type = "string" }, step_id = { type = "string" }, status = { type = "string" }, blocking = { type = "boolean" }, asked_by = { type = "string" }, question = { type = "string" } }, { "run_id", "question" }), handler = "record_question", call = record_question },
    { name = "project_pipelines.answer_question", description = "Answer one durable Project Pipelines question.", input_schema = object_schema({ question_id = { type = "string" }, answer = { type = "string" }, answered_by = { type = "string" } }, { "question_id", "answer" }), handler = "answer_question", call = answer_question },
    { name = "project_pipelines.link_pr", description = "Link a pull request to a run.", input_schema = object_schema({ run_id = { type = "string" }, url = { type = "string" }, provider = { type = "string" }, status = { type = "string" } }, { "run_id", "url" }), handler = "link_pr", call = link_pr },
    { name = "project_pipelines.request_step_advance", description = "Advance a run when durable gates, reviews, findings, dependencies, commit evidence, and PR linkage allow it.", input_schema = object_schema({ run_id = { type = "string" }, next_step_id = { type = "string" }, request_id = { type = "string" } }, { "run_id" }), handler = "request_step_advance", call = request_step_advance },
    { name = "project_pipelines.resolve_repository_playbook", description = "Resolve exactly one supported repository ownership charter.", input_schema = object_schema({ repository = { type = "string" }, repository_name = { type = "string" }, name = { type = "string" }, path = { type = "string" } }), handler = "resolve_repository_playbook", call = resolve_repository_playbook },
    { name = "project_pipelines.current_context", description = "Return persisted Project Pipelines context.", input_schema = object_schema({ run_id = { type = "string" } }), handler = "current_context", call = current_context },
    { name = "project_pipelines.entities", description = "Return Project Pipelines entity frames.", input_schema = empty_schema(), handler = "entities", call = entities },
  },
  handlers = {
    { id = "home_surface", kind = "surface_route", descriptor_id = "project-pipelines.home", descriptor = { title = "Project Pipelines", surface_id = "project-pipelines.home" }, call = render_home },
    { id = "settings_surface", kind = "surface_route", descriptor_id = "project-pipelines.settings", descriptor = { title = "Project Pipelines Settings", surface_id = "project-pipelines.settings" }, call = render_settings },
    { id = "create_ticket_action", kind = "ui_action", descriptor_id = "project_pipelines.create_ticket", descriptor = { action_id = "project_pipelines.create_ticket", surface_id = "project-pipelines.home" }, call = create_ticket_action },
    { id = "record_run_action", kind = "ui_action", descriptor_id = "project_pipelines.record_run", descriptor = { action_id = "project_pipelines.record_run", surface_id = "project-pipelines.home" }, call = record_run_action },
    { id = "activate_step_action", kind = "ui_action", descriptor_id = "project_pipelines.activate_step", descriptor = { action_id = "project_pipelines.activate_step", surface_id = "project-pipelines.home" }, call = activate_step_action },
    { id = "filter_action", kind = "ui_action", descriptor_id = "project_pipelines.filter", descriptor = { action_id = "project_pipelines.filter", surface_id = "project-pipelines.home" }, call = filter_action },
    { id = "select_row_action", kind = "ui_action", descriptor_id = "project_pipelines.select_row", descriptor = { action_id = "project_pipelines.select_row", surface_id = "project-pipelines.home" }, call = select_row_action },
  },
})
