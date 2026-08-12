local STORE_SCHEMA_VERSION = 4
local STORE_ROOT = "v4/"
local SOURCE_REVISION = "botster-stack-delivery/2026-08-05.1"
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
  "project_targets",
  "tickets",
  "ticket_dependencies",
  "pipeline_definitions",
  "runs",
  "run_steps",
  "gate_results",
  "reviews",
  "findings",
  "artifacts",
  "checklists",
  "checklist_items",
  "questions",
  "answers",
  "question_orchestrators",
  "pr_links",
  -- Events are diagnostic consequences and are always written last.
  "events",
}

local function object_schema(properties, required)
  local schema = {
    type = "object",
    properties = properties,
    additionalProperties = true,
  }
  if type(required) == "table" and #required > 0 then schema.required = required end
  return schema
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

-- Map durable engine codes to short operator copy. Keep technical repair names
-- (field ids, config keys) so the attention queue and forms stay actionable.
local function operator_error_message(error)
  if type(error) ~= "table" then return "Action rejected" end
  local code = error.code
  local message = error.message or "Action rejected"
  if code == "session_type_id_required" then
    return message
  end
  if code == "session_types_unavailable" then
    return "Hub session types are unavailable. Check package capabilities and Hub version."
  end
  if code == "session_type_spawn_failed" then
    return "Session type spawn failed: " .. message
  end
  if code == "provider_dependency_missing" then
    return message
  end
  if code == "ticket_dependencies_unmet" then
    return "Open ticket dependencies block this step. Close or remove them, then retry."
  end
  if code == "validation_failed" or code == "not_found" or code == "id_conflict" then
    return message
  end
  if code == "missing_argument" then
    return message
  end
  if code == "persist_failed" then
    return "Could not save workflow state. Retry after the plugin database is writable."
  end
  if code then
    return message .. " (" .. tostring(code) .. ")"
  end
  return message
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
    local message = operator_error_message(error)
    local fields = {}
    for _, field in ipairs(error.fields or {}) do
      local field_id = options.field_ids and options.field_ids[field] or field
      fields[field_id] = { message }
    end
    local state = error.code == "validation_failed" and "rejected" or "error"
    local extra = {
      error = message,
      form_errors = { message },
      payload = response,
      normalized_values = copy(values),
    }
    if error.code then extra.error_code = error.code end
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
      project_target = 0,
      ticket_dependency = 0,
      run_step = 0,
      question_orchestrator = 0,
    },
    projects = {},
    project_targets = {},
    tickets = {},
    ticket_dependencies = {},
    pipeline_definitions = {},
    runs = {},
    run_steps = {},
    gate_results = {},
    reviews = {},
    findings = {},
    artifacts = {},
    checklists = {},
    checklist_items = {},
    questions = {},
    answers = {},
    question_orchestrators = {},
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
  project_targets = { "id", "project_id", "target_id" },
  tickets = { "id", "project_id", "title", "status" },
  ticket_dependencies = { "id", "ticket_id", "depends_on_ticket_id" },
  pipeline_definitions = { "id", "name", "steps" },
  runs = { "id", "ticket_id", "pipeline_definition_id", "current_step_id", "status" },
  run_steps = { "id", "run_id", "step_id", "status" },
  gate_results = { "id", "run_id", "step_id", "gate_id", "status" },
  reviews = { "id", "run_id", "step_id", "verdict" },
  findings = { "id", "run_id", "review_id", "severity", "status" },
  artifacts = { "id", "run_id", "kind" },
  checklists = { "id", "name" },
  checklist_items = { "id", "checklist_id", "text", "status" },
  questions = { "id", "question", "status" },
  answers = { "id", "question_id", "answer" },
  question_orchestrators = { "id", "scope", "session_uuid" },
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

-- BEGIN one-time v3-to-v4 session-type migration
-- Scoped to a single chunk-level name so the retired vocabulary stays confined to the
-- one-time rewrite and the module keeps room under Lua's 200 active-local ceiling.
local migrate_v3_store
do
  local LEGACY_STORE_ROOT = "v3/"
  -- Exact identity the package itself wrote, in write precedence order.
  local LEGACY_IDENTITY_KEYS = { "session_template_id", "template_id" }
  -- Every selector key the package wrote onto a record it owns. These are removed only from
  -- the specific records that carried them, never from nested caller payloads.
  local LEGACY_SELECTOR_KEYS = {
    "session_template_id",
    "template_id",
    "session_template_name",
    "template_name",
    "session_template_capability",
    "session_capability",
    "template_selector",
  }

  local LEGACY_EVENT_KINDS = {
    session_template_spawn_requested = "session_type_spawn_requested",
    session_template_spawn_failed = "session_type_spawn_failed",
    session_template_spawn_blocked = "session_type_spawn_blocked",
  }

  local LEGACY_DIAGNOSTIC_CODES = {
    session_template_resolution_unavailable = "session_type_resolution_unavailable",
    session_template_resolution_failed = "session_type_resolution_failed",
    session_template_unavailable = "session_type_unavailable",
    session_templates_unavailable = "session_types_unavailable",
    session_template_spawn_failed = "session_type_spawn_failed",
  }

  local LEGACY_DIAGNOSTIC_MESSAGES = {
    ["hub session template resolution capability is unavailable"] = "hub session type resolution capability is unavailable",
    ["session template selector is unavailable"] = "session type id is unavailable",
    ["no hub session template matched selector"] = "no hub session type matched id",
    ["hub session template spawn capability is unavailable"] = "hub session type spawn capability is unavailable",
    ["managed session template spawn capability is unavailable"] = "managed session type spawn capability is unavailable",
  }

  -- Rewrites one record's OWN identity fields and nothing else. Nested tables are copied
  -- through byte-for-byte, because request context, metadata, and Hub results are caller- and
  -- agent-authored evidence in which a legacy-looking key name means nothing to this package.
  local function migrate_record_identity(record)
    if type(record) ~= "table" then return record end
    local migrated = copy(record)
    local identity
    for _, key in ipairs(LEGACY_IDENTITY_KEYS) do
      local value = record[key]
      if identity == nil and type(value) == "string" and value ~= "" then identity = value end
    end
    for _, key in ipairs(LEGACY_SELECTOR_KEYS) do migrated[key] = nil end
    if migrated.session_type_id == nil then migrated.session_type_id = identity end
    return migrated
  end

  local function migrate_diagnostic(diagnostic)
    if type(diagnostic) ~= "table" then return diagnostic end
    local migrated = migrate_record_identity(diagnostic)
    migrated.code = LEGACY_DIAGNOSTIC_CODES[diagnostic.code] or diagnostic.code
    migrated.message = LEGACY_DIAGNOSTIC_MESSAGES[diagnostic.message] or diagnostic.message
    return migrated
  end

  local function migrate_v3_payload(family, payload)
    if type(payload) ~= "table" then return payload end
    if family == "pipeline_definitions" then
      local migrated = copy(payload)
      for index, legacy_step in ipairs(array(payload.steps)) do
        local migrated_step = migrate_record_identity(legacy_step)
        migrated.steps[index] = migrated_step
        local had_unmappable_selector = legacy_step.session_template_name
          or legacy_step.template_name
          or legacy_step.session_template_capability
          or legacy_step.session_capability
        if not migrated_step.session_type_id and had_unmappable_selector then
          migrated_step.session_type_id_required = true
        end
      end
      return migrated
    end
    if family == "session_requests" then
      local migrated = migrate_record_identity(payload)
      migrated.request = migrate_record_identity(payload.request)
      migrated.result = migrate_record_identity(payload.result)
      -- A blocked or failed activation persisted the SAME diagnostic twice: once as
      -- session_request.diagnostic and once inside the result envelope as result.error. They
      -- are one table at write time but two independent copies once durable, so both have to
      -- be migrated or a consumer reading the envelope still sees the retired contract.
      if type(migrated.result) == "table" then
        migrated.result.error = migrate_diagnostic(payload.result.error)
      end
      migrated.diagnostic = migrate_diagnostic(payload.diagnostic)
      return migrated
    end
    if family == "events" then
      local migrated = migrate_record_identity(payload)
      migrated.kind = LEGACY_EVENT_KINDS[payload.kind] or payload.kind
      migrated.payload = migrate_record_identity(payload.payload)
      if type(migrated.payload) == "table" then
        migrated.payload.diagnostic = migrate_diagnostic(payload.payload.diagnostic)
      end
      return migrated
    end
    if family == "runs" then
      local migrated = copy(payload)
      migrated.diagnostic = migrate_diagnostic(payload.diagnostic)
      migrated.blocked_reason = LEGACY_DIAGNOSTIC_MESSAGES[payload.blocked_reason] or payload.blocked_reason
      return migrated
    end
    return copy(payload)
  end

  function migrate_v3_store(plugin_db, namespace_entries)
    local legacy_entries = {}
    local obsolete_entries = {}
    local has_current_entries = false
    for _, entry in ipairs(namespace_entries) do
      if type(entry.key) == "string" then
        if entry.key:sub(1, #LEGACY_STORE_ROOT) == LEGACY_STORE_ROOT then
          table.insert(legacy_entries, entry)
        elseif entry.key:sub(1, #STORE_ROOT) == STORE_ROOT then
          has_current_entries = true
        elseif entry.key:sub(1, 3) == "v2/" then
          table.insert(obsolete_entries, entry)
        end
      end
    end
    if #legacy_entries == 0 and #obsolete_entries == 0 then return namespace_entries end
    if #legacy_entries > 0 and has_current_entries then
      error("store_migration_conflict: v3 and v4 records coexist")
    end
    if type(plugin_db.batch) ~= "function" then
      error("store_migration_failed: atomic plugin_db.batch capability is unavailable")
    end

    local mutations = {}
    for _, entry in ipairs(legacy_entries) do
      local response = plugin_db.get({ key = entry.key })
      local payload = record_payload(response)
      if not payload then error("store_migration_failed: unreadable record " .. entry.key) end
      local suffix = entry.key:sub(#LEGACY_STORE_ROOT + 1)
      local family = suffix:match("^([^/]+)/")
      table.insert(mutations, {
        operation = "set",
        key = STORE_ROOT .. suffix,
        schema_version = STORE_SCHEMA_VERSION,
        payload = migrate_v3_payload(family, payload),
        expected_revision = 0,
      })
      table.insert(mutations, {
        operation = "delete",
        key = entry.key,
        expected_revision = entry.revision or 0,
      })
    end
    for _, entry in ipairs(obsolete_entries) do
      table.insert(mutations, {
        operation = "delete",
        key = entry.key,
        expected_revision = entry.revision or 0,
      })
    end

    local invoked, migration = pcall(plugin_db.batch, { mutations = mutations })
    if not invoked or type(migration) ~= "table" or migration.ok ~= true then
      error("store_migration_failed: " .. tostring(invoked and (migration.error_kind or migration.message) or migration))
    end
    return list_entries(plugin_db.list({ prefix = "" }))
  end
end
-- END one-time v3-to-v4 session-type migration

local function load_state()
  local plugin_db = store()
  local state = default_state()
  if not plugin_db or type(plugin_db.get) ~= "function" or type(plugin_db.list) ~= "function" then
    return state
  end

  local namespace_entries = migrate_v3_store(plugin_db, list_entries(plugin_db.list({ prefix = "" })))
  state._store_key_count = #namespace_entries
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
  -- Normalized rows are the sole dependency shape. Remove non-authoritative
  -- ticket fields from projections and from the next atomic write.
  for _, ticket in ipairs(state.tickets) do ticket.dependency_ticket_ids = nil end
  return state
end

local function save_state(state)
  local plugin_db = store()
  if not plugin_db or type(plugin_db.batch) ~= "function" then
    return failure("persist_failed", "atomic plugin_db.batch capability is unavailable")
  end

  local mutations = {}
  local mutation_records = {}
  local deleted_records = {}
  local new_key_count = 0
  for _, family in ipairs(RECORD_FAMILIES) do
    local current = {}
    for _, record in ipairs(state[family] or {}) do current[record.id] = true end
    for id in pairs(state._originals and state._originals[family] or {}) do
      if not current[id] then
        table.insert(deleted_records, { family = family, id = id })
      end
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
  local projected_keys = (state._store_key_count or 0) - #deleted_records + new_key_count
  if projected_keys > MAX_STORE_KEYS - STORE_KEY_HEADROOM then
    return failure("store_capacity_exhausted", "project-pipelines store has reached its reserved key ceiling", {
      projected_keys = projected_keys,
      maximum_keys = MAX_STORE_KEYS,
      reserved_headroom = STORE_KEY_HEADROOM,
    })
  end

  for _, deleted in ipairs(deleted_records) do
    table.insert(mutations, {
      operation = "delete",
      key = record_key(deleted.family, deleted.id),
      expected_revision = state._revisions[deleted.family][deleted.id],
    })
    table.insert(mutation_records, { kind = "delete", family = deleted.family, id = deleted.id })
  end

  if not deep_equal(state.counters, state._original_counters or {}) then
    table.insert(mutations, {
      operation = "set",
      key = STORE_ROOT .. "meta/counters",
      schema_version = STORE_SCHEMA_VERSION,
      payload = state.counters,
      expected_revision = state._counter_revision or 0,
    })
    table.insert(mutation_records, { kind = "counters" })
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
        table.insert(mutations, {
          operation = "set",
          key = record_key(family, record.id),
          schema_version = STORE_SCHEMA_VERSION,
          payload = payload,
          expected_revision = revision,
        })
        table.insert(mutation_records, {
          kind = "record",
          family = family,
          id = record.id,
          record = record,
          payload = payload,
          previous_revision = revision,
        })
      end
    end
  end

  if #mutations == 0 then return nil end
  local invoked, response = pcall(plugin_db.batch, { mutations = mutations })
  if not invoked then
    return failure("persist_failed", "atomic plugin_db batch failed", { reason = tostring(response) })
  end
  if type(response) ~= "table" or response.ok ~= true then
    return failure("persist_failed", "atomic plugin_db batch rejected", {
      error_kind = response and response.error_kind,
      message = response and response.message,
      mutation_index = response and response.mutation_index,
      key = response and response.key,
    })
  end

  for index, metadata in ipairs(mutation_records) do
    local result = type(response.results) == "table" and response.results[index] or nil
    local revision = result and result.record and result.record.revision
    if metadata.kind == "delete" then
      state._originals[metadata.family][metadata.id] = nil
      state._positions[metadata.family][metadata.id] = nil
      state._revisions[metadata.family][metadata.id] = nil
    elseif metadata.kind == "counters" then
      state._counter_revision = revision or (state._counter_revision or 0) + 1
      state._original_counters = copy(state.counters)
    else
      state._revisions[metadata.family][metadata.id] = revision or metadata.previous_revision + 1
      state._originals[metadata.family][metadata.id] = copy(metadata.record)
      state._positions[metadata.family][metadata.id] = metadata.payload._store_position
    end
  end
  state._store_key_count = projected_keys
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
    agent_name = agent_name,
    prompt = role_prompt .. "\n\n" .. routing_prompt(),
    allows_open_ticket_dependencies = options.allows_open_ticket_dependencies == true,
    gates = options.gates or {},
    next_step_id = options.next_step_id,
    on_approved_step_id = options.on_approved_step_id or options.next_step_id,
    on_changes_requested_step_id = options.on_changes_requested_step_id,
    on_blocked_step_id = options.on_blocked_step_id,
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
        on_changes_requested_step_id = "botster_stack_plan",
        on_blocked_step_id = "botster_stack_plan",
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
        on_changes_requested_step_id = "botster_stack_implement",
        on_blocked_step_id = "botster_stack_implement",
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

local function step_uses_session_type(step)
  if type(step) ~= "table" then return false end
  local mode = step.kind or step.execution or step.run_mode or step.mode
  return mode == "pty" or mode == "session" or mode == "session_type"
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
  -- A declared entry always yields a descriptor, even an unusable one. Skipping it here would
  -- drop the whole gate, so a malformed declaration must reach the availability check and fail
  -- closed rather than disappear.
  for _, source in ipairs(sources) do
    if type(source) == "table" then
      for _, dependency in ipairs(source) do
        if type(dependency) == "string" then
          return { dependency = dependency ~= "" and dependency or nil }
        elseif type(dependency) == "table" then
          return {
            dependency = dependency.dependency or dependency.id or dependency.name or dependency.capability,
            provider = dependency.provider,
            capability = dependency.capability,
          }
        else
          return {}
        end
      end
    end
  end
  return nil
end

local function provider_dependency_available(dependency, capabilities)
  if not dependency then return true end
  -- A step that declares a prerequisite it cannot name is a broken declaration, not an absent
  -- one. Reporting it available would let a declaration silently disable the gate it requested.
  if type(dependency.dependency) ~= "string" or dependency.dependency == "" then return false end
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

local function resolve_session_type_id(arguments, step, capabilities)
  local dependency = first_required_provider_dependency(step)
  if dependency and not provider_dependency_available(dependency, capabilities) then
    return blocked_diagnostic("provider_dependency_missing", "required provider dependency is unavailable", {
      dependency = dependency.dependency,
      provider = dependency.provider,
      capability = dependency.capability,
    })
  end
  local explicit = string_arg(arguments, "session_type_id")
  if explicit then return ok({ session_type_id = explicit, source = "explicit" }) end
  local configured = string_arg(step, "session_type_id")
  if configured then return ok({ session_type_id = configured, source = "step" }) end
  if step and step.session_type_id_required == true then
    return blocked_diagnostic("session_type_id_required", "this migrated step requires an operator-supplied session_type_id", {
      step_id = step.id,
    })
  end
  local config = capabilities and capabilities.config
  if config and type(config.get) == "function" then
    local invoked, response = pcall(config.get)
    if invoked and type(response) == "table" then
      local configured_value = response.values and response.values.default_session_type_id
      local fallback = type(configured_value) == "table"
        and string_arg(configured_value, "value")
        or string_arg(response.values, "default_session_type_id")
      if fallback then return ok({ session_type_id = fallback, source = "configuration" }) end
    end
  end
  -- This is also the upgrade diagnostic. The pre-v4 configuration key was renamed, and the Hub
  -- only exposes fields the installed manifest declares, so an upgraded install reaches here
  -- with no default at all. Name the repair in the message: it is what the operator reads in
  -- run.blocked_reason and in the needs-attention queue.
  return blocked_diagnostic(
    "session_type_id_required",
    "an exact session_type_id is required for PTY-backed pipeline steps; set the package configuration field default_session_type_id and reload the package",
    { step_id = step and step.id }
  )
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

local function build_session_type_request(arguments, run, ticket, project, step)
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

local function spawn_session_type(session_type_id, request)
  local capabilities = botster and botster.capabilities or {}
  local session_types = capabilities.session_types
  if not session_types then
    return failure("session_types_unavailable", "hub session type spawn capability is unavailable")
  end

  if type(session_types.ensure_worktree_and_spawn) ~= "function" then
    return failure("session_types_unavailable", "managed session type spawn capability is unavailable")
  end
  local operation = session_types.ensure_worktree_and_spawn
  local dispatched_request = {
    session_type_id = session_type_id,
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
    return failure("session_type_spawn_failed", tostring(response)), dispatched_request
  end
  if type(response) == "table" and response.ok == true and type(response.result) == "table" then
    return response.result, dispatched_request
  end
  return response, dispatched_request
end

local function create_project(arguments)
  arguments = arguments or {}
  local name = trim(arguments.name)
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local repository = table_arg(arguments, "repository")
  if not repository then
    repository = {
      id = string_arg(arguments, "repository_id") or name,
      name = string_arg(arguments, "repository_name") or name,
      remote = string_arg(arguments, "repository_remote") or "local",
    }
  end
  local spawn_target_id = trim(arguments.spawn_target_id) or trim(arguments.target_id) or "unassigned"

  local state = load_state()
  local requested_id = string_arg(arguments, "id")
  local existing = requested_id and find_by_id(state.projects, requested_id) or nil
  if existing then
    if existing.name ~= name or existing.spawn_target_id ~= spawn_target_id then return failure("id_conflict", "project id belongs to different content") end
    return ok({ project = existing, adopted = true })
  end
  local project = {
    id = requested_id or next_id(state, "project"),
    mode = string_arg(arguments, "workspace_id") and "workspace_linked" or "standalone",
    name = name,
    repository = repository,
    spawn_target_id = spawn_target_id,
    workspace_id = string_arg(arguments, "workspace_id"),
    description = string_arg(arguments, "description"),
    status = string_arg(arguments, "status") or "active",
  }
  table.insert(state.projects, project)
  local err = save_state(state)
  if err then return err end
  return ok({ project = project })
end

local function list_projects(arguments)
  arguments = arguments or {}
  local projects = {}
  for _, project in ipairs(load_state().projects) do
    if not arguments.status or project.status == arguments.status then table.insert(projects, project) end
  end
  return ok({ projects = projects })
end

local function create_ticket(arguments)
  arguments = arguments or {}
  local project_id = trim(arguments.project_id)
  if not project_id or project_id == "" then return failure("validation_failed", "project_id is required", { "project_id" }) end
  local title = trim(arguments.title)
  if not title or title == "" then return failure("validation_failed", "title is required", { "title" }) end
  local state = load_state()
  if not find_by_id(state.projects, project_id) then return failure("not_found", "project not found: " .. project_id) end
  if arguments.dependency_ticket_ids ~= nil and type(arguments.dependency_ticket_ids) ~= "table" then
    return failure("validation_failed", "dependency_ticket_ids must be an array", { "dependency_ticket_ids" })
  end
  local requested_id = string_arg(arguments, "id")
  local existing = requested_id and find_by_id(state.tickets, requested_id) or nil
  local ticket_id = requested_id or next_id(state, "ticket")
  local dependency_ticket_ids = {}
  local seen_dependency_ids = {}
  for _, dependency_ticket_id in ipairs(array(arguments.dependency_ticket_ids)) do
    if type(dependency_ticket_id) ~= "string" or dependency_ticket_id == "" then
      return failure("validation_failed", "dependency_ticket_ids must contain ticket ids", { "dependency_ticket_ids" })
    end
    if dependency_ticket_id == ticket_id then
      return failure("validation_failed", "ticket cannot depend on itself", { "dependency_ticket_ids" })
    end
    if not find_by_id(state.tickets, dependency_ticket_id) then
      return failure("not_found", "dependency ticket not found: " .. dependency_ticket_id)
    end
    if not seen_dependency_ids[dependency_ticket_id] then
      seen_dependency_ids[dependency_ticket_id] = true
      table.insert(dependency_ticket_ids, dependency_ticket_id)
    end
  end
  if existing then
    if existing.project_id ~= project_id or existing.title ~= title then return failure("id_conflict", "ticket id belongs to different content") end
    if arguments.dependency_ticket_ids ~= nil then
      local existing_dependency_ids = {}
      local existing_dependency_count = 0
      for _, dependency in ipairs(state.ticket_dependencies) do
        if dependency.ticket_id == existing.id then
          existing_dependency_ids[dependency.depends_on_ticket_id] = true
          existing_dependency_count = existing_dependency_count + 1
        end
      end
      if existing_dependency_count ~= #dependency_ticket_ids then
        return failure("id_conflict", "ticket id belongs to different dependency content")
      end
      for _, dependency_ticket_id in ipairs(dependency_ticket_ids) do
        if not existing_dependency_ids[dependency_ticket_id] then
          return failure("id_conflict", "ticket id belongs to different dependency content")
        end
      end
    end
    return ok({ ticket = existing, adopted = true })
  end
  local ticket = {
    id = ticket_id,
    project_id = project_id,
    workspace_id = string_arg(arguments, "workspace_id"),
    title = title,
    description = string_arg(arguments, "description"),
    status = string_arg(arguments, "status") or "open",
    target_id = string_arg(arguments, "target_id"),
  }
  table.insert(state.tickets, ticket)
  for _, dependency_ticket_id in ipairs(dependency_ticket_ids) do
    table.insert(state.ticket_dependencies, {
      id = next_id(state, "ticket_dependency"),
      ticket_id = ticket.id,
      depends_on_ticket_id = dependency_ticket_id,
    })
  end
  push_event(state, "ticket_created", nil, ticket.id)
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function list_tickets(arguments)
  arguments = arguments or {}
  local state = load_state()
  local project_id = string_arg(arguments, "project_id")
  local tickets = {}
  for _, ticket in ipairs(state.tickets) do
    if (not project_id or ticket.project_id == project_id)
      and (not arguments.status or ticket.status == arguments.status)
    then table.insert(tickets, ticket) end
  end
  return ok({ tickets = tickets })
end

-- Step-transition namespace: route derivation, waiting-transition lifecycle, and wakeup
-- reconciliation. This main chunk is at Lua's 200-local ceiling, so these helpers share
-- one table instead of each taking a top-level local.
local step_transitions = {}

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
  for _, existing in ipairs(state.ticket_dependencies) do
    if existing.ticket_id == ticket.id and existing.depends_on_ticket_id == dependency_ticket_id then
      return ok({ ticket = ticket, dependency = existing })
    end
  end
  local dependency = {
    id = string_arg(arguments, "id") or next_id(state, "ticket_dependency"),
    ticket_id = ticket.id,
    depends_on_ticket_id = dependency_ticket_id,
  }
  table.insert(state.ticket_dependencies, dependency)
  push_event(state, "ticket_dependency_added", nil, ticket.id, { dependency_ticket_id = dependency_ticket_id })
  step_transitions.reconcile_waiting(state)
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket, dependency = dependency })
end

local function remove_ticket_dependency(arguments)
  arguments = arguments or {}
  local ticket_id = string_arg(arguments, "ticket_id")
  local dependency_ticket_id = string_arg(arguments, "dependency_ticket_id") or string_arg(arguments, "depends_on_ticket_id")
  local state = load_state()
  local dependency_id = string_arg(arguments, "dependency_id")
  if dependency_id then
    local dependency = find_by_id(state.ticket_dependencies, dependency_id)
    if not dependency then return failure("not_found", "ticket dependency not found: " .. dependency_id) end
    ticket_id = ticket_id or dependency.ticket_id
    dependency_ticket_id = dependency_ticket_id or dependency.depends_on_ticket_id
  end
  if not ticket_id then return failure("validation_failed", "ticket_id is required", { "ticket_id" }) end
  if not dependency_ticket_id then return failure("validation_failed", "dependency_ticket_id is required", { "dependency_ticket_id" }) end
  local ticket = find_by_id(state.tickets, ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. ticket_id) end
  local removed
  for index = #state.ticket_dependencies, 1, -1 do
    local dependency = state.ticket_dependencies[index]
    if dependency.ticket_id == ticket.id and dependency.depends_on_ticket_id == dependency_ticket_id then
      removed = table.remove(state.ticket_dependencies, index)
    end
  end
  if not removed then return ok({ ticket = ticket }) end
  push_event(state, "ticket_dependency_removed", nil, ticket.id, { dependency_ticket_id = dependency_ticket_id })
  step_transitions.reconcile_waiting(state)
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket })
end

local function unmet_ticket_dependencies(state, ticket)
  local unmet = {}
  if not ticket then return unmet end
  for _, dependency in ipairs(state.ticket_dependencies) do
    if dependency.ticket_id == ticket.id then
      local dependency_ticket = find_by_id(state.tickets, dependency.depends_on_ticket_id)
      if not dependency_ticket or dependency_ticket.status ~= "closed" then
        table.insert(unmet, {
          dependency_id = dependency.id,
          dependency_ticket_id = dependency.depends_on_ticket_id,
          status = dependency_ticket and (dependency_ticket.status or "open") or "missing",
        })
      end
    end
  end
  return unmet
end

function step_transitions.clear_waiting(state, run, reason)
  local waiting = run.waiting_transition
  if type(waiting) ~= "table" then return false end
  run.waiting_transition = nil
  push_event(state, "ticket_dependencies_waiting_cleared", run.id, waiting.target_step_id, {
    source_step_id = waiting.source_step_id,
    source_run_step_id = waiting.source_run_step_id,
    request_id = waiting.request_id,
    reason = reason,
  })
  return true
end

function step_transitions.clear_waiting_for_ticket(state, ticket_id, reason)
  for _, run in ipairs(state.runs) do
    if run.ticket_id == ticket_id then step_transitions.clear_waiting(state, run, reason) end
  end
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
  local name = trim(arguments.name)
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local state = load_state()
  local project_id = trim(arguments.project_id)
  if project_id and not find_by_id(state.projects, project_id) then return failure("not_found", "project not found: " .. project_id) end
  local requested_id = string_arg(arguments, "id")
  local existing = requested_id and find_by_id(state.pipeline_definitions, requested_id) or nil
  if existing then
    if existing.name ~= name then return failure("id_conflict", "pipeline id belongs to different content") end
    return ok({ pipeline_definition = existing, pipeline = existing, adopted = true })
  end
  local steps = array(arguments.steps)
  for index, step in ipairs(steps) do
    step.id = step.id or ("step_" .. index)
    step.position = step.position or index
    step.gates = array(step.gates)
  end
  local pipeline = {
    id = requested_id or next_id(state, "pipeline_definition"),
    project_id = project_id,
    name = name,
    description = string_arg(arguments, "description"),
    merge_policy = string_arg(arguments, "merge_policy") or "pr",
    version_label = string_arg(arguments, "version_label"),
    supersedes_pipeline_id = string_arg(arguments, "supersedes_pipeline_id"),
    steps = steps,
  }
  table.insert(state.pipeline_definitions, pipeline)
  local err = save_state(state)
  if err then return err end
  return ok({ pipeline_definition = pipeline, pipeline = pipeline })
end

local function show_pipeline_definition(arguments)
  local id = string_arg(arguments, "pipeline_definition_id") or string_arg(arguments, "id")
  if not id then return failure("missing_argument", "pipeline_definition_id is required") end
  local pipeline = find_by_id(load_state().pipeline_definitions, id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. id) end
  return ok({ pipeline_definition = pipeline })
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

  if not step_uses_session_type(step) then
    run.current_step_id = step.id
    push_event(state, "step_started", run.id, step.id)
    local activation = {
      run_id = run.id,
      step_id = step.id,
      spawned = false,
      status = "preserved_non_pty",
      reason = "step is not a PTY-backed session-type step",
    }
    push_event(state, "step_activation_preserved", run.id, step.id, activation)
    local err = save_state(state)
    if err then return err end
    return ok({ activation = activation, run = run })
  end

  request_id = request_id or next_id(state, "session_request")
  local request = build_session_type_request(arguments, run, ticket, project, step)
  if not request.target_id or request.target_id == "" then
    return failure("validation_failed", "spawn target is required for session-type activation", { "target_id" })
  end
  local resolved = resolve_session_type_id(arguments, step, botster and botster.capabilities or {})
  if resolved and resolved.ok == false then
    local session_request = {
      id = request_id,
      run_id = run.id,
      step_id = step.id,
      ticket_id = ticket.id,
      session_type_id = nil,
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
    push_event(state, "session_type_spawn_blocked", run.id, session_request.id, {
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
    session_type_id = resolved.session_type_id,
    session_type_id_source = resolved.source,
    status = "spawning",
    request = request,
    prompt_summary = bounded_prompt(request.context and request.context.prompt),
  }
  table.insert(state.session_requests, session_request)
  local pending_error = save_state(state)
  if pending_error then return pending_error end

  local response, dispatched_request = spawn_session_type(resolved.session_type_id, request)
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
  local event_kind = status == "failed" and "session_type_spawn_failed" or "session_type_spawn_requested"
  push_event(state, event_kind, run.id, session_request.id, {
    session_type_id = resolved.session_type_id,
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
  local ticket_id = trim(arguments.ticket_id)
  local question_text = trim(arguments.question)
  if not run_id and not ticket_id then return failure("validation_failed", "run_id or ticket_id is required", { "run_id", "ticket_id" }) end
  if not question_text or question_text == "" then return failure("validation_failed", "question is required", { "question" }) end
  local state = load_state()
  if run_id and not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  if ticket_id and not find_by_id(state.tickets, ticket_id) then return failure("not_found", "ticket not found: " .. ticket_id) end
  local question = {
    id = string_arg(arguments, "id") or next_id(state, "question"),
    run_id = run_id,
    ticket_id = ticket_id,
    step_id = string_arg(arguments, "step_id"),
    kind = string_arg(arguments, "kind") or "human",
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
  local run_step_id = string_arg(arguments, "run_step_id") or run.current_run_step_id
  local run_step = find_by_id(state.run_steps, run_step_id)
  if not run_step or run_step.run_id ~= run.id or run_step.step_id ~= step_id then
    return failure("validation_failed", "run_step_id must identify this run and step", { "run_step_id" })
  end
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
    if candidate.run_id == run_id and candidate.run_step_id == run_step_id and candidate.gate_id == gate_id then
      result = candidate
    end
  end
  if not result then
    result = {
      id = string_arg(arguments, "id") or next_id(state, "gate_result"),
      run_id = run_id,
      run_step_id = run_step_id,
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
  -- Gate results are transition authorization inputs, so a retained waiting transition
  -- must be re-evaluated in the same atomic save that changes them.
  step_transitions.reconcile_waiting(state)
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
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  local run_step_id = string_arg(arguments, "run_step_id") or run.current_run_step_id
  local run_step = find_by_id(state.run_steps, run_step_id)
  if not run_step or run_step.run_id ~= run.id or run_step.step_id ~= step_id then
    return failure("validation_failed", "run_step_id must identify this run and step", { "run_step_id" })
  end
  local review = {
    id = string_arg(arguments, "id") or next_id(state, "review"),
    run_id = run_id,
    run_step_id = run_step_id,
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
  -- Reviews and their findings are transition authorization inputs; re-evaluate any
  -- retained waiting transition in the same atomic save.
  step_transitions.reconcile_waiting(state)
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
  local status = string_arg(arguments, "status") or "resolved"
  if status ~= "resolved" and status ~= "waived" then return failure("validation_failed", "status must be resolved or waived") end
  finding.status = status
  finding.resolution = string_arg(arguments, "resolution")
  push_event(state, "finding_resolved", finding.run_id, finding.id)
  -- Unresolved blocker/high findings are transition authorization inputs; resolving or
  -- waiving one can restore a retained waiting transition.
  step_transitions.reconcile_waiting(state)
  local err = save_state(state)
  if err then return err end
  return ok({ finding = finding })
end

local function create_checklist(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  local owner_id = string_arg(arguments, "owner_id") or run_id
  local name = trim(arguments.name)
  if not owner_id then return failure("validation_failed", "owner_id or run_id is required", { "owner_id" }) end
  if not name or name == "" then return failure("validation_failed", "name is required", { "name" }) end
  local state = load_state()
  if not run_id and find_by_id(state.runs, owner_id) then run_id = owner_id end
  if run_id and not find_by_id(state.runs, run_id) then return failure("not_found", "run not found: " .. run_id) end
  local checklist = {
    id = string_arg(arguments, "id") or next_id(state, "checklist"),
    run_id = run_id,
    owner_id = owner_id,
    scope = string_arg(arguments, "scope") or (run_id and "run" or "ticket"),
    step_id = string_arg(arguments, "step_id"),
    source = string_arg(arguments, "source") or "pipeline",
    name = name,
    description = string_arg(arguments, "description"),
  }
  table.insert(state.checklists, checklist)
  for position, input in ipairs(array(arguments.items)) do
    local prompt = trim(input.prompt)
    if not prompt then return failure("validation_failed", "checklist item prompt is required", { "items" }) end
    table.insert(state.checklist_items, {
      id = string_arg(input, "id") or next_id(state, "checklist_item"),
      checklist_id = checklist.id,
      run_id = run_id,
      prompt = prompt,
      text = prompt,
      position = input.position or position,
      status = string_arg(input, "status") or "pending",
      source_ref = string_arg(input, "source_ref"),
      evidence = type(input.evidence) == "table" and copy(input.evidence) or nil,
    })
  end
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
    prompt = text,
    position = arguments.position or (#state.checklist_items + 1),
    status = string_arg(arguments, "status") or "pending",
    source_ref = string_arg(arguments, "source_ref"),
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
  local url = trim(arguments.url or arguments.pr_url)
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
    pr_url = url,
    repo = string_arg(arguments, "repo"),
    pr_number = arguments.pr_number,
    provider = string_arg(arguments, "provider") or "github",
    status = string_arg(arguments, "status") or "open",
    base_branch = string_arg(arguments, "base_branch"),
    head_branch = string_arg(arguments, "head_branch"),
  }
  table.insert(state.pr_links, link)
  push_event(state, "pr_linked", run_id, link.id)
  local err = save_state(state)
  if err then return err end
  return ok({ pr_link = link })
end

local function gate_result_for(state, run_id, run_step_id, step_id, gate_id)
  local selected
  for _, result in ipairs(state.gate_results) do
    if result.run_id == run_id and result.run_step_id == run_step_id
      and result.step_id == step_id and result.gate_id == gate_id
    then
      selected = result
    end
  end
  return selected
end

local function review_for_current_visit(state, run, step)
  local selected
  for _, review in ipairs(state.reviews) do
    if review.run_id == run.id and review.run_step_id == run.current_run_step_id
      and review.step_id == step.id
    then
      selected = review
    end
  end
  return selected
end

local function transition_blockers(state, run, pipeline, step)
  local blockers = {}
  for _, gate in ipairs(array(step.gates)) do
    local result = gate_result_for(state, run.id, run.current_run_step_id, step.id, gate.id)
    if gate.required ~= false and (not result or result.status ~= "passed") then
      table.insert(blockers, { kind = "gate", gate_id = gate.id })
    end
  end
  local latest_review = review_for_current_visit(state, run, step)
  if (step.on_changes_requested_step_id or step.on_blocked_step_id)
    and not latest_review
  then
    table.insert(blockers, { kind = "review_missing", run_step_id = run.current_run_step_id })
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
    local result = gate_result_for(state, run.id, run.current_run_step_id, step.id, "implementation")
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
    local result = gate_result_for(state, run.id, run.current_run_step_id, step.id, "verification")
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

local function dependency_blockers_for_step(state, ticket, step)
  if step.allows_open_ticket_dependencies == true then return {} end
  return unmet_ticket_dependencies(state, ticket)
end

-- Single authority for the route a source visit is currently allowed to take.
-- Advancement and waiting-transition wakeup both derive the target from this so a
-- review verdict landed while waiting cannot be applied against a stale route.
function step_transitions.route_for(state, run, current_step, requested_next_step_id)
  local latest_review = review_for_current_visit(state, run, current_step)
  if latest_review and latest_review.verdict == "approved" then
    return current_step.on_approved_step_id or current_step.next_step_id, false, latest_review
  end
  if latest_review and latest_review.verdict == "changes_required" then
    return current_step.on_changes_requested_step_id, true, latest_review
  end
  if latest_review and latest_review.verdict == "blocked" then
    return current_step.on_blocked_step_id, true, latest_review
  end
  return requested_next_step_id or current_step.next_step_id, false, nil
end

-- Revalidate a waiting transition against current review, gate, and finding state.
-- Gate overrides recorded on the transition waive exactly the gate ids the operator
-- named; nothing else carries forward from the original request.
function step_transitions.waiting_authorization_blockers(state, run, pipeline, waiting)
  local source_step = find_pipeline_step(pipeline, waiting.source_step_id)
  if not source_step then
    return { { kind = "source_step_missing", step_id = waiting.source_step_id } }
  end
  local route, review_rework = step_transitions.route_for(state, run, source_step, waiting.target_step_id)
  if route ~= waiting.target_step_id then
    return { {
      kind = "route_changed",
      waiting_step_id = waiting.target_step_id,
      current_step_id = route,
    } }
  end
  if review_rework then return {} end
  local overridden = array(waiting.overridden_gate_ids)
  local blockers = {}
  for _, blocker in ipairs(transition_blockers(state, run, pipeline, source_step)) do
    if not (blocker.kind == "gate" and table_contains(overridden, blocker.gate_id)) then
      table.insert(blockers, blocker)
    end
  end
  return blockers
end

local function transition_response(run, source_step_id, target_step_id)
  local response_run = copy(run)
  response_run.current_step_id = target_step_id
  response_run.status = "active"
  response_run.waiting_transition = nil
  return ok({ run = response_run, previous_step_id = source_step_id, step_id = target_step_id })
end

local function apply_step_transition(state, run, transition, recovered)
  if run.current_step_id ~= transition.source_step_id
    or run.current_run_step_id ~= transition.source_run_step_id
  then
    return failure("transition_source_changed", "waiting transition no longer matches the current run-step visit")
  end
  local previous_run_step = find_by_id(state.run_steps, transition.source_run_step_id)
  if not previous_run_step then
    return failure("transition_source_missing", "waiting transition source run-step is missing")
  end
  -- The gate override is an audit fact about an applied advancement, so it is recorded
  -- here rather than when the override was requested; a request that never advances
  -- (dependency wait, remaining blockers) must not leave a consumed override behind.
  local overridden_gate_ids = array(transition.overridden_gate_ids)
  if #overridden_gate_ids > 0 then
    push_event(state, "gates_overridden", run.id, transition.source_step_id, {
      run_step_id = transition.source_run_step_id,
      gate_ids = copy(overridden_gate_ids),
      reason = transition.override_reason,
    })
  end
  previous_run_step.status = "done"
  run.current_step_id = transition.target_step_id
  run.status = "active"
  local run_step = {
    id = next_id(state, "run_step"), run_id = run.id, step_id = transition.target_step_id,
    status = "active", sequence = (previous_run_step.sequence or 0) + 1,
  }
  table.insert(state.run_steps, run_step)
  run.current_run_step_id = run_step.id
  run.waiting_transition = nil
  push_event(state, "step_advanced", run.id, transition.target_step_id, {
    from_step_id = transition.source_step_id,
    request_id = transition.request_id,
    recovered = recovered == true,
  })
  if transition.advance_request_id then
    local request = find_by_id(state.advance_requests, transition.advance_request_id)
    if request then request.status = "applied" end
  end
  return transition.result or transition_response(run, transition.source_step_id, transition.target_step_id)
end

-- Park an authorized-but-unappliable transition as durable waiting state. Dependency and
-- authorization holds share one record so the operator sees a single reason set.
function step_transitions.hold(state, run, transition, dependencies, authorization)
  local waiting = run.waiting_transition
  local first_wait = type(waiting) ~= "table"
    or waiting.source_run_step_id ~= transition.source_run_step_id
    or waiting.target_step_id ~= transition.target_step_id
  local previously_unauthorized = type(waiting) == "table" and waiting.unauthorized == true
  local blocked_by_dependencies = #dependencies > 0
  transition.status = "waiting"
  transition.code = blocked_by_dependencies and "ticket_dependencies_unmet" or "transition_authorization_changed"
  transition.unmet_dependencies = blocked_by_dependencies and copy(dependencies) or nil
  transition.unauthorized = #authorization > 0 or nil
  transition.unmet_authorization = #authorization > 0 and copy(authorization) or nil
  run.waiting_transition = copy(transition)
  if first_wait then
    push_event(state, "ticket_dependencies_waiting", run.id, transition.target_step_id, {
      source_step_id = transition.source_step_id,
      source_run_step_id = transition.source_run_step_id,
      request_id = transition.request_id,
      unmet_dependencies = copy(dependencies),
    })
  end
  if #authorization > 0 and not previously_unauthorized then
    push_event(state, "ticket_dependencies_waiting_unauthorized", run.id, transition.target_step_id, {
      source_step_id = transition.source_step_id,
      source_run_step_id = transition.source_run_step_id,
      request_id = transition.request_id,
      blockers = copy(authorization),
    })
  end
  return diagnostic_failure(
    transition.code,
    blocked_by_dependencies and "ticket has open blocking dependencies"
      or "the authorization that justified this transition no longer holds",
    {
      status = "waiting",
      run_id = run.id,
      step_id = transition.source_step_id,
      next_step_id = transition.target_step_id,
      waiting_transition = copy(run.waiting_transition),
      unmet_dependencies = copy(dependencies),
      unmet_authorization = copy(authorization),
    }
  )
end

-- The single authority for applying a previously requested transition. A correlated
-- retry and dependency-clearance wakeup are the same operation and must satisfy the same
-- two conditions: the ticket's blocking dependencies are met, and the authorization that
-- justified the original request still holds. Returns (applied_result, hold_failure).
function step_transitions.settle(state, run, pipeline, ticket, target_step, transition)
  local dependencies = dependency_blockers_for_step(state, ticket, target_step)
  local authorization = step_transitions.waiting_authorization_blockers(state, run, pipeline, transition)
  if #dependencies == 0 and #authorization == 0 then
    return apply_step_transition(state, run, transition, true), nil
  end
  return nil, step_transitions.hold(state, run, transition, dependencies, authorization)
end

local function request_step_advance(arguments)
  arguments = arguments or {}
  local run_id = string_arg(arguments, "run_id")
  if not run_id then return failure("validation_failed", "run_id is required", { "run_id" }) end
  local state = load_state()
  local run = find_by_id(state.runs, run_id)
  if not run then return failure("not_found", "run not found: " .. run_id) end
  local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
  if not pipeline then return failure("not_found", "pipeline definition not found: " .. run.pipeline_definition_id) end
  local ticket = find_by_id(state.tickets, run.ticket_id)
  if not ticket then return failure("not_found", "ticket not found: " .. tostring(run.ticket_id)) end
  local request_id = string_arg(arguments, "request_id")
  if request_id then
    for _, request in ipairs(state.advance_requests) do
      if request.request_id == request_id then
        if request.run_id ~= run.id then
          return failure("request_id_conflict", "advance request_id belongs to another run")
        end
        if run.current_step_id == request.previous_step_id then
          local target_step = find_pipeline_step(pipeline, request.step_id)
          if not target_step then return failure("not_found", "step not found: " .. tostring(request.step_id)) end
          -- While a request is parked, run.waiting_transition is the authority: it carries
          -- the exact source visit and any gate override the operator authorized.
          -- Rebuilding from the advance_request alone would silently drop that override.
          local waiting = run.waiting_transition
          local transition
          if type(waiting) == "table"
            and waiting.request_id == request.request_id
            and waiting.source_step_id == request.previous_step_id
            and waiting.target_step_id == request.step_id
            and waiting.source_run_step_id == run.current_run_step_id
          then
            transition = copy(waiting)
          else
            transition = {
              source_step_id = request.previous_step_id,
              source_run_step_id = run.current_run_step_id,
              target_step_id = request.step_id,
              request_id = request.request_id,
              result = copy(request.result),
            }
          end
          transition.advance_request_id = request.id
          local applied, held = step_transitions.settle(state, run, pipeline, ticket, target_step, transition)
          if held then
            local waiting_error = save_state(state)
            if waiting_error then return waiting_error end
            return held
          end
          if applied.ok == false then return applied end
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
  local current_step = find_pipeline_step(pipeline, run.current_step_id)
  if not current_step then return failure("not_found", "current step not found: " .. tostring(run.current_step_id)) end
  local next_step_id, review_rework, latest_review =
    step_transitions.route_for(state, run, current_step, string_arg(arguments, "next_step_id"))
  if review_rework and not next_step_id then
    return failure("review_route_missing", "current step has no route for review verdict " .. latest_review.verdict)
  end
  if not next_step_id then return failure("terminal_step", "current step has no next step") end
  local next_step = find_pipeline_step(pipeline, next_step_id)
  if not next_step then return failure("not_found", "next step not found: " .. next_step_id) end
  local blockers = review_rework and {} or transition_blockers(state, run, pipeline, current_step)
  local overridden_gate_ids = {}
  local override_reason
  if arguments.override_unmet_gates == true then
    override_reason = trim(arguments.override_reason)
    if not override_reason or override_reason == "" then
      return failure("validation_failed", "override_reason is required when override_unmet_gates is true", { "override_reason" })
    end
    local remaining = {}
    for _, blocker in ipairs(blockers) do
      if blocker.kind == "gate" then
        table.insert(overridden_gate_ids, blocker.gate_id)
      else
        table.insert(remaining, blocker)
      end
    end
    blockers = remaining
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
  local response = transition_response(run, current_step.id, next_step_id)
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
  end
  local transition = {
    source_step_id = current_step.id,
    source_run_step_id = run.current_run_step_id,
    target_step_id = next_step_id,
    request_id = request_id,
    advance_request_id = advance_request and advance_request.id,
    overridden_gate_ids = #overridden_gate_ids > 0 and copy(overridden_gate_ids) or nil,
    override_reason = #overridden_gate_ids > 0 and override_reason or nil,
    result = copy(response),
  }
  local dependencies = dependency_blockers_for_step(state, ticket, next_step)
  if #dependencies > 0 then
    local blocked = step_transitions.hold(state, run, transition, dependencies, {})
    local waiting_error = save_state(state)
    if waiting_error then return waiting_error end
    return blocked
  end
  if advance_request then
    local correlation_error = save_state(state)
    if correlation_error then return correlation_error end
    state = load_state()
    run = find_by_id(state.runs, run_id)
    ticket = find_by_id(state.tickets, run.ticket_id)
    advance_request = find_by_id(state.advance_requests, advance_request.id)
    transition.advance_request_id = advance_request.id
    dependencies = dependency_blockers_for_step(state, ticket, next_step)
    if #dependencies > 0 then
      local blocked = step_transitions.hold(state, run, transition, dependencies, {})
      local waiting_error = save_state(state)
      if waiting_error then return waiting_error end
      return blocked
    end
  end
  local applied = apply_step_transition(state, run, transition, false)
  if applied.ok == false then return applied end
  local err = save_state(state)
  if err then return err end
  return response
end

-- A waiting transition may only be applied while the run, its ticket, and the preserved
-- source visit are all still explicitly resumable. Anything terminal (cancelled run,
-- merged/closed run, closed ticket, completed source visit) fails closed so dependency
-- clearance can never resurrect work an operator already ended.
function step_transitions.waiting_resumable(state, run, waiting)
  if run.status ~= "active" then return false end
  local ticket = find_by_id(state.tickets, run.ticket_id)
  if not ticket or ticket.status == "closed" then return false end
  local source_visit = find_by_id(state.run_steps, waiting.source_run_step_id)
  if not source_visit or source_visit.status ~= "active" then return false end
  if run.current_step_id ~= waiting.source_step_id then return false end
  if run.current_run_step_id ~= waiting.source_run_step_id then return false end
  return true, ticket
end

function step_transitions.reconcile_waiting(state)
  local applied = {}
  for _, run in ipairs(state.runs) do
    local waiting = run.waiting_transition
    if type(waiting) == "table" then
      local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
      local target_step = pipeline and find_pipeline_step(pipeline, waiting.target_step_id) or nil
      local resumable, ticket = step_transitions.waiting_resumable(state, run, waiting)
      if resumable and target_step then
        local result = step_transitions.settle(state, run, pipeline, ticket, target_step, waiting)
        if result and result.ok ~= false then table.insert(applied, run.id) end
      end
    end
  end
  return applied
end

local function records_for_run(records, run_id)
  if not run_id then return records end
  local selected = {}
  for _, record in ipairs(records) do
    if record.run_id == run_id or record.id == run_id then table.insert(selected, record) end
  end
  return selected
end

local function persist_response(state, key, record)
  local err = save_state(state)
  if err then return err end
  return ok({ [key] = record })
end

local function remove_by_id(records, id)
  for index, record in ipairs(records) do
    if record.id == id then return table.remove(records, index) end
  end
  return nil
end

local function update_fields(record, arguments, fields)
  for _, field in ipairs(fields) do
    if arguments[field] ~= nil then record[field] = copy(arguments[field]) end
  end
  return record
end

local function add_project_target(arguments)
  arguments = arguments or {}
  local state = load_state()
  local project = find_by_id(state.projects, string_arg(arguments, "project_id"))
  local target_id = string_arg(arguments, "target_id")
  if not project or not target_id then return failure("validation_failed", "project_id and target_id are required") end
  for _, target in ipairs(state.project_targets) do
    if target.project_id == project.id and target.target_id == target_id then return ok({ project_target = target }) end
  end
  local target = { id = string_arg(arguments, "id") or next_id(state, "project_target"), project_id = project.id, target_id = target_id }
  table.insert(state.project_targets, target)
  return persist_response(state, "project_target", target)
end

local function remove_project_target(arguments)
  arguments = arguments or {}
  local state = load_state()
  local removed
  for index, target in ipairs(state.project_targets) do
    local matches_id = string_arg(arguments, "project_target_id") == target.id
    local matches_pair = target.project_id == string_arg(arguments, "project_id")
      and target.target_id == string_arg(arguments, "target_id")
    if matches_id or matches_pair then
      removed = table.remove(state.project_targets, index)
      break
    end
  end
  if not removed then return failure("not_found", "project target not found") end
  return persist_response(state, "project_target", removed)
end

local function update_project(arguments)
  arguments = arguments or {}
  local state = load_state()
  local project = find_by_id(state.projects, string_arg(arguments, "project_id"))
  if not project then return failure("not_found", "project not found") end
  update_fields(project, arguments, { "name", "description", "status", "workspace_id", "spawn_target_id" })
  return persist_response(state, "project", project)
end

local function delete_project(arguments)
  arguments = arguments or {}
  local state = load_state()
  local id = string_arg(arguments, "project_id")
  for _, ticket in ipairs(state.tickets) do
    if ticket.project_id == id then return failure("project_not_empty", "delete project tickets first") end
  end
  local project = remove_by_id(state.projects, id)
  if not project then return failure("not_found", "project not found") end
  for index = #state.project_targets, 1, -1 do
    if state.project_targets[index].project_id == id then table.remove(state.project_targets, index) end
  end
  return persist_response(state, "project", project)
end

local function update_ticket(arguments)
  arguments = arguments or {}
  local state = load_state()
  local ticket = find_by_id(state.tickets, string_arg(arguments, "ticket_id"))
  if not ticket then return failure("not_found", "ticket not found") end
  update_fields(ticket, arguments, { "title", "description", "project_id", "target_id", "status" })
  if ticket.status == "closed" then
    step_transitions.clear_waiting_for_ticket(state, ticket.id, "ticket_closed")
  end
  step_transitions.reconcile_waiting(state)
  return persist_response(state, "ticket", ticket)
end

local function get_ticket(arguments)
  arguments = arguments or {}
  local state = load_state()
  local ticket = find_by_id(state.tickets, string_arg(arguments, "ticket_id"))
  if not ticket then return failure("not_found", "ticket not found") end
  local runs, run_steps, session_requests, dependencies, findings, questions = {}, {}, {}, {}, {}, {}
  for _, run in ipairs(state.runs) do if run.ticket_id == ticket.id then table.insert(runs, run) end end
  for _, run in ipairs(runs) do
    for _, run_step in ipairs(state.run_steps) do if run_step.run_id == run.id then table.insert(run_steps, run_step) end end
    for _, request in ipairs(state.session_requests) do if request.run_id == run.id then table.insert(session_requests, request) end end
  end
  for _, dependency in ipairs(state.ticket_dependencies) do if dependency.ticket_id == ticket.id then table.insert(dependencies, dependency) end end
  for _, finding in ipairs(state.findings) do
    for _, run in ipairs(runs) do if finding.run_id == run.id then table.insert(findings, finding); break end end
  end
  for _, question in ipairs(state.questions) do if question.ticket_id == ticket.id then table.insert(questions, question) end end
  return ok({
    ticket = ticket,
    project = find_by_id(state.projects, ticket.project_id),
    runs = runs,
    run_steps = run_steps,
    session_requests = session_requests,
    dependencies = dependencies,
    findings = findings,
    questions = questions,
  })
end

local function get_project(arguments)
  arguments = arguments or {}
  local state = load_state()
  local project = find_by_id(state.projects, string_arg(arguments, "project_id"))
  if not project then return failure("not_found", "project not found") end
  local tickets, targets = {}, {}
  for _, ticket in ipairs(state.tickets) do if ticket.project_id == project.id then table.insert(tickets, ticket) end end
  for _, target in ipairs(state.project_targets) do if target.project_id == project.id then table.insert(targets, target) end end
  return ok({ project = project, tickets = tickets, targets = targets })
end

local function delete_ticket(arguments)
  arguments = arguments or {}
  local state = load_state()
  local id = string_arg(arguments, "ticket_id")
  for _, run in ipairs(state.runs) do
    if run.ticket_id == id then return failure("ticket_has_runs", "delete ticket runs first") end
  end
  local ticket = remove_by_id(state.tickets, id)
  if not ticket then return failure("not_found", "ticket not found") end
  for index = #state.ticket_dependencies, 1, -1 do
    local dependency = state.ticket_dependencies[index]
    if dependency.ticket_id == id or dependency.depends_on_ticket_id == id then table.remove(state.ticket_dependencies, index) end
  end
  step_transitions.reconcile_waiting(state)
  return persist_response(state, "ticket", ticket)
end

local function search_tickets(arguments)
  arguments = arguments or {}
  local selected = {}
  local query = trim(arguments.query or "") or ""
  query = query:lower()
  for _, ticket in ipairs(load_state().tickets) do
    local matches = query == "" or tostring(ticket.title or ""):lower():find(query, 1, true) or tostring(ticket.description or ""):lower():find(query, 1, true)
    if matches and (not arguments.status or ticket.status == arguments.status)
      and (not arguments.project_id or ticket.project_id == arguments.project_id)
      and (arguments.include_closed == true or ticket.status ~= "closed")
    then table.insert(selected, ticket) end
    if arguments.limit and #selected >= arguments.limit then break end
  end
  return ok({ tickets = selected })
end

local function list_ticket_dependencies(arguments)
  arguments = arguments or {}
  local selected = {}
  local state = load_state()
  for _, dependency in ipairs(state.ticket_dependencies) do
    local dependency_ticket = find_by_id(state.tickets, dependency.depends_on_ticket_id)
    local blocking = not dependency_ticket or dependency_ticket.status ~= "closed"
    if (not arguments.ticket_id or dependency.ticket_id == arguments.ticket_id)
      and (arguments.blocking_only ~= true or blocking)
    then
      local result = copy(dependency)
      result.blocking = blocking
      result.depends_on_status = dependency_ticket and dependency_ticket.status or "missing"
      table.insert(selected, result)
    end
  end
  return ok({ dependencies = selected })
end

local function create_pipeline(arguments)
  arguments = arguments or {}
  arguments.pipeline_definition_id = arguments.id
  return define_pipeline(arguments)
end

local function get_pipeline(arguments)
  arguments = arguments or {}
  arguments.pipeline_definition_id = arguments.pipeline_id
  return show_pipeline_definition(arguments)
end

local function list_pipelines(arguments)
  arguments = arguments or {}
  local pipelines = {}
  for _, pipeline in ipairs(load_state().pipeline_definitions) do
    if arguments.include_archived == true or pipeline.archived_at == nil then table.insert(pipelines, pipeline) end
  end
  return ok({ pipelines = pipelines })
end

local function update_pipeline(arguments)
  arguments = arguments or {}
  local state = load_state()
  local pipeline = find_by_id(state.pipeline_definitions, string_arg(arguments, "pipeline_id"))
  if not pipeline then return failure("not_found", "pipeline not found") end
  if arguments.archived ~= nil then
    pipeline.archived_at = arguments.archived == true and "archived" or nil
  end
  if arguments.supersedes_pipeline_id ~= nil then
    pipeline.replacement_pipeline_id = copy(arguments.supersedes_pipeline_id)
  end
  update_fields(pipeline, arguments, { "name", "description", "merge_policy", "version_label", "archived_at", "replacement_pipeline_id" })
  return persist_response(state, "pipeline", pipeline)
end

local function delete_pipeline(arguments)
  arguments = arguments or {}
  local state = load_state()
  local id = string_arg(arguments, "pipeline_id")
  for _, run in ipairs(state.runs) do if run.pipeline_definition_id == id then return failure("pipeline_has_runs", "pipeline has runs") end end
  local pipeline = remove_by_id(state.pipeline_definitions, id)
  if not pipeline then return failure("not_found", "pipeline not found") end
  return persist_response(state, "pipeline", pipeline)
end

local function create_step(arguments)
  arguments = arguments or {}
  local state = load_state()
  local pipeline = find_by_id(state.pipeline_definitions, string_arg(arguments, "pipeline_id"))
  if not pipeline then return failure("not_found", "pipeline not found") end
  local step = copy(arguments)
  step.id = string_arg(arguments, "id") or (pipeline.id .. "_step_" .. tostring(#array(pipeline.steps) + 1))
  step.position = arguments.position or #array(pipeline.steps) + 1
  step.kind = string_arg(arguments, "kind") or "agent"
  step.gates = array(arguments.gates)
  pipeline.steps = array(pipeline.steps)
  table.insert(pipeline.steps, step)
  return persist_response(state, "step", step)
end

local function find_step_state(state, step_id)
  for _, pipeline in ipairs(state.pipeline_definitions) do
    local step = find_pipeline_step(pipeline, step_id)
    if step then return pipeline, step end
  end
end

local function update_step(arguments)
  arguments = arguments or {}
  local state = load_state()
  local _, step = find_step_state(state, string_arg(arguments, "step_id"))
  if not step then return failure("not_found", "step not found") end
  update_fields(step, arguments, { "name", "position", "kind", "agent_name", "prompt", "command", "session_type_id", "next_step_id", "on_approved_step_id", "on_changes_requested_step_id", "on_blocked_step_id" })
  if string_arg(arguments, "session_type_id") then step.session_type_id_required = nil end
  return persist_response(state, "step", step)
end

local function update_step_agent(arguments)
  arguments = arguments or {}
  arguments.agent_name = arguments.agent_name or arguments.agent
  return update_step(arguments)
end

local function delete_step(arguments)
  arguments = arguments or {}
  local state = load_state()
  local pipeline, step = find_step_state(state, string_arg(arguments, "step_id"))
  if not step then return failure("not_found", "step not found") end
  remove_by_id(pipeline.steps, step.id)
  return persist_response(state, "step", step)
end

local function create_gate(arguments)
  arguments = arguments or {}
  local state = load_state()
  local _, step = find_step_state(state, string_arg(arguments, "step_id"))
  if not step then return failure("not_found", "step not found") end
  step.gates = array(step.gates)
  local gate = copy(arguments)
  gate.id = string_arg(arguments, "id") or (step.id .. "_gate_" .. tostring(#step.gates + 1))
  table.insert(step.gates, gate)
  return persist_response(state, "gate", gate)
end

local function update_gate(arguments)
  arguments = arguments or {}
  local state = load_state()
  for _, pipeline in ipairs(state.pipeline_definitions) do for _, step in ipairs(array(pipeline.steps)) do
    local gate = find_by_id(array(step.gates), string_arg(arguments, "gate_id"))
    if gate then
      update_fields(gate, arguments, { "kind", "prompt", "required_fields", "command" })
      return persist_response(state, "gate", gate)
    end
  end end
  return failure("not_found", "gate not found")
end

local function delete_gate(arguments)
  arguments = arguments or {}
  local state = load_state()
  for _, pipeline in ipairs(state.pipeline_definitions) do for _, step in ipairs(array(pipeline.steps)) do
    local gate = remove_by_id(array(step.gates), string_arg(arguments, "gate_id"))
    if gate then return persist_response(state, "gate", gate) end
  end end
  return failure("not_found", "gate not found")
end

local function start_run(arguments)
  arguments = arguments or {}
  local state = load_state()
  local ticket = find_by_id(state.tickets, string_arg(arguments, "ticket_id"))
  local pipeline_id = string_arg(arguments, "pipeline_id") or string_arg(arguments, "pipeline_definition_id")
  local pipeline = find_by_id(state.pipeline_definitions, pipeline_id)
  if not ticket or not pipeline then return failure("not_found", "ticket and pipeline are required") end
  local requested_id = string_arg(arguments, "id")
  local existing = requested_id and find_by_id(state.runs, requested_id) or nil
  if existing then
    if existing.ticket_id ~= ticket.id or existing.pipeline_definition_id ~= pipeline.id then
      return failure("id_conflict", "run id belongs to different content")
    end
    return ok({ run = existing, run_step = find_by_id(state.run_steps, existing.current_run_step_id), ticket = ticket, adopted = true })
  end
  if ticket.status == "closed" then return failure("ticket_closed", "closed tickets cannot start runs") end
  local dependencies = unmet_ticket_dependencies(state, ticket)
  if #dependencies > 0 then return diagnostic_failure("ticket_dependencies_unmet", "ticket dependencies are not closed", { dependencies = dependencies }) end
  local first_step = array(pipeline.steps)[1]
  if not first_step then return failure("pipeline_empty", "pipeline has no steps") end
  local run = {
    id = requested_id or next_id(state, "run"), ticket_id = ticket.id,
    pipeline_id = pipeline.id, pipeline_definition_id = pipeline.id, current_step_id = first_step.id,
    status = "active", target_id = string_arg(arguments, "target_id") or string_arg(arguments, "spawn_target_id") or ticket.target_id,
    spawn_target_id = string_arg(arguments, "spawn_target_id") or string_arg(arguments, "target_id") or ticket.target_id,
    workspace_name = string_arg(arguments, "workspace_name"), parent_run_id = string_arg(arguments, "parent_run_id"),
    branch = string_arg(arguments, "branch"), base_ref = string_arg(arguments, "base_ref"),
    worktree = table_arg(arguments, "worktree"), worktree_id = string_arg(arguments, "worktree_id"),
  }
  local run_step = { id = next_id(state, "run_step"), run_id = run.id, step_id = first_step.id, status = "active", sequence = 1 }
  run.current_run_step_id = run_step.id
  ticket.status = "active"
  table.insert(state.runs, run)
  table.insert(state.run_steps, run_step)
  push_event(state, "run_started", run.id, ticket.id)
  local err = save_state(state)
  if err then return err end
  return ok({ run = run, run_step = run_step, ticket = ticket })
end

local function create_child_run(arguments)
  arguments = arguments or {}
  local state = load_state()
  local parent = find_by_id(state.runs, string_arg(arguments, "parent_run_id"))
  if not parent then return failure("not_found", "parent run not found") end
  local parent_ticket = find_by_id(state.tickets, parent.ticket_id)
  if not parent_ticket then return failure("not_found", "parent ticket not found") end
  local title = trim(arguments.title)
  if not title or title == "" then return failure("validation_failed", "title is required", { "title" }) end
  local pipeline_id = string_arg(arguments, "pipeline_id") or parent.pipeline_definition_id
  local pipeline = find_by_id(state.pipeline_definitions, pipeline_id)
  if not pipeline then return failure("not_found", "pipeline not found: " .. tostring(pipeline_id)) end
  local first_step = array(pipeline.steps)[1]
  if not first_step then return failure("pipeline_empty", "pipeline has no steps") end

  local ticket = {
    id = string_arg(arguments, "ticket_id") or next_id(state, "ticket"),
    project_id = parent_ticket.project_id,
    workspace_id = string_arg(arguments, "workspace_id") or parent_ticket.workspace_id,
    title = title,
    description = string_arg(arguments, "description"),
    status = "active",
    target_id = string_arg(arguments, "target_id") or parent.target_id or parent_ticket.target_id,
    parent_ticket_id = parent_ticket.id,
  }
  if find_by_id(state.tickets, ticket.id) then return failure("id_conflict", "ticket id already exists") end
  local run = {
    id = string_arg(arguments, "id") or next_id(state, "run"),
    ticket_id = ticket.id,
    pipeline_id = pipeline.id,
    pipeline_definition_id = pipeline.id,
    current_step_id = first_step.id,
    status = "active",
    target_id = ticket.target_id,
    spawn_target_id = ticket.target_id,
    workspace_name = string_arg(arguments, "workspace_name"),
    parent_run_id = parent.id,
    base_ref = string_arg(arguments, "base_ref"),
    base_run_id = string_arg(arguments, "base_run_id") or parent.id,
    base_ticket_id = string_arg(arguments, "base_ticket_id") or parent_ticket.id,
    base_target_path = string_arg(arguments, "base_target_path"),
  }
  if find_by_id(state.runs, run.id) then return failure("id_conflict", "run id already exists") end
  local run_step = {
    id = next_id(state, "run_step"), run_id = run.id, step_id = first_step.id,
    status = "active", sequence = 1,
  }
  run.current_run_step_id = run_step.id
  table.insert(state.tickets, ticket)
  table.insert(state.runs, run)
  table.insert(state.run_steps, run_step)
  push_event(state, "ticket_created", nil, ticket.id, { parent_ticket_id = parent_ticket.id })
  push_event(state, "run_started", run.id, ticket.id, { parent_run_id = parent.id })
  local err = save_state(state)
  if err then return err end
  return ok({ ticket = ticket, run = run, run_step = run_step })
end

local function finish_run(arguments, run_status, ticket_status)
  arguments = arguments or {}
  local state = load_state()
  local run = find_by_id(state.runs, string_arg(arguments, "run_id"))
  if not run then return failure("not_found", "run not found") end
  local ticket = find_by_id(state.tickets, run.ticket_id)
  run.status = run_status
  if ticket then ticket.status = ticket_status end
  local run_step = find_by_id(state.run_steps, run.current_run_step_id)
  if run_step then run_step.status = run_status end
  step_transitions.clear_waiting(state, run, "run_" .. run_status)
  push_event(state, "run_" .. run_status, run.id, ticket and ticket.id, {
    reason = string_arg(arguments, "reason"),
  })
  local err = save_state(state)
  if err then return err end
  return ok({ run = run, run_step = run_step, ticket = ticket })
end

local function cancel_run(arguments) return finish_run(arguments, "cancelled", "open") end
local function request_merge(arguments) return finish_run(arguments, "merge_requested", "active") end

local function close_ticket(arguments)
  arguments = arguments or {}
  local state = load_state()
  local ticket = find_by_id(state.tickets, string_arg(arguments, "ticket_id"))
  if not ticket then return failure("not_found", "ticket not found") end
  local requires_merge_confirmation = false
  local has_merged_link = false
  for _, run in ipairs(state.runs) do
    if run.ticket_id == ticket.id then
      local pipeline = find_by_id(state.pipeline_definitions, run.pipeline_definition_id)
      if pipeline and pipeline.merge_policy == "pr" then requires_merge_confirmation = true end
      for _, link in ipairs(state.pr_links) do
        if link.run_id == run.id and link.status == "merged" then has_merged_link = true end
      end
    end
  end
  if requires_merge_confirmation and not has_merged_link and arguments.merge_confirmed ~= true then
    return failure("merge_confirmation_required", "PR-policy ticket requires a merged link or merge_confirmed=true", { "merge_confirmed" })
  end
  ticket.status = "closed"
  ticket.merge_confirmed = arguments.merge_confirmed == true or has_merged_link
  ticket.merge_commit = string_arg(arguments, "merge_commit")
  ticket.pr_url = string_arg(arguments, "pr_url")
  ticket.merge_summary = string_arg(arguments, "merge_summary")
  ticket.base_branch = string_arg(arguments, "base_branch")
  for _, run in ipairs(state.runs) do
    if run.ticket_id == ticket.id then
      if run.status ~= "closed" and run.status ~= "cancelled" then
        run.status = "closed"
        local run_step = find_by_id(state.run_steps, run.current_run_step_id)
        if run_step then run_step.status = "closed" end
      end
      step_transitions.clear_waiting(state, run, "ticket_closed")
    end
  end
  push_event(state, "ticket_closed", nil, ticket.id)
  step_transitions.reconcile_waiting(state)
  return persist_response(state, "ticket", ticket)
end

local function handle_pr_merged(arguments)
  arguments = arguments or {}
  local state = load_state()
  local run = string_arg(arguments, "run_id") and find_by_id(state.runs, arguments.run_id) or nil
  local matched_link
  for _, link in ipairs(state.pr_links) do
    if (arguments.pr_url and (link.url == arguments.pr_url or link.pr_url == arguments.pr_url))
      or (arguments.pr_number and link.pr_number == arguments.pr_number and (not arguments.repo or link.repo == arguments.repo))
      or (run and link.run_id == run.id)
    then matched_link = link; run = run or find_by_id(state.runs, link.run_id); break end
  end
  if not run then return failure("not_found", "merged PR is not linked to a run") end
  local ticket = find_by_id(state.tickets, run.ticket_id)
  run.status = "closed"
  if ticket then ticket.status = "closed" end
  local run_step = find_by_id(state.run_steps, run.current_run_step_id)
  if run_step then run_step.status = "closed" end
  step_transitions.clear_waiting(state, run, "provider_pr_merged")
  if matched_link then
    matched_link.status = "merged"
    matched_link.merge_commit = string_arg(arguments, "merge_commit")
  end
  push_event(state, "provider_pr_merged", run.id, matched_link and matched_link.id, { merge_commit = arguments.merge_commit })
  step_transitions.reconcile_waiting(state)
  local err = save_state(state)
  if err then return err end
  return ok({ run = run, run_step = run_step, ticket = ticket, pr_link = matched_link })
end

local function retry_step_agent(arguments)
  arguments = arguments or {}
  arguments.request_id = arguments.request_id or ("retry:" .. tostring(arguments.run_id) .. ":" .. tostring(arguments.step_id or "current"))
  return activate_step(arguments)
end

local function spawn_ticket_session(arguments)
  arguments = arguments or {}
  local state = load_state()
  local run = arguments.run_id and find_by_id(state.runs, arguments.run_id) or nil
  if not run then return failure("not_found", "run not found") end
  return activate_step(arguments)
end

local function list_checklists(arguments)
  arguments = arguments or {}
  local state = load_state()
  local selected = {}
  for _, checklist in ipairs(state.checklists) do
    if (not arguments.run_id or checklist.run_id == arguments.run_id)
      and (not arguments.owner_id or checklist.owner_id == arguments.owner_id or checklist.run_id == arguments.owner_id)
      and (not arguments.scope or checklist.scope == arguments.scope)
    then table.insert(selected, checklist) end
  end
  return ok({ checklists = selected })
end

local function get_checklist(arguments)
  arguments = arguments or {}
  local state = load_state()
  local checklist = find_by_id(state.checklists, string_arg(arguments, "checklist_id"))
  if not checklist then return failure("not_found", "checklist not found") end
  local items = {}
  for _, item in ipairs(state.checklist_items) do if item.checklist_id == checklist.id then table.insert(items, item) end end
  return ok({ checklist = checklist, items = items })
end

local function update_checklist(arguments)
  arguments = arguments or {}
  local state = load_state()
  local checklist = find_by_id(state.checklists, string_arg(arguments, "checklist_id"))
  if not checklist then return failure("not_found", "checklist not found") end
  update_fields(checklist, arguments, { "name", "description", "source", "scope", "owner_id" })
  return persist_response(state, "checklist", checklist)
end

local function update_checklist_item(arguments)
  arguments = arguments or {}
  local state = load_state()
  local item = find_by_id(state.checklist_items, string_arg(arguments, "item_id"))
  if not item then return failure("not_found", "checklist item not found") end
  if arguments.prompt ~= nil then arguments.text = arguments.prompt end
  update_fields(item, arguments, { "text", "status", "position", "source_ref", "evidence" })
  item.prompt = item.text
  return persist_response(state, "item", item)
end

local function create_vault_checklist(arguments)
  arguments = arguments or {}
  arguments.source = "vault"
  arguments.name = arguments.name or "Vault workflow"
  arguments.items = arguments.items or {
    { prompt = "Load applicable vault/project conventions before planning.", source_ref = "vault:context" },
    { prompt = "Check the implementation plan against loaded conventions.", source_ref = "vault:plan-review" },
    { prompt = "Verify with repository-approved commands.", source_ref = "vault:verification" },
    { prompt = "Capture durable knowledge or record why none was needed.", source_ref = "vault:capture" },
  }
  return create_checklist(arguments)
end

local function checklist_instructions()
  return ok({
    purpose = "Track workflow evidence while vault notes remain the convention source of truth.",
    required_evidence = { "notes_read", "convention_conflicts", "verification_commands", "capture_path_or_reason" },
  })
end

local function list_pr_links(arguments)
  arguments = arguments or {}
  local selected = {}
  for _, link in ipairs(load_state().pr_links) do
    if (not arguments.ticket_id or link.ticket_id == arguments.ticket_id)
      and (not arguments.run_id or link.run_id == arguments.run_id)
      and (not arguments.provider or link.provider == arguments.provider)
      and (not arguments.repo or link.repo == arguments.repo)
    then table.insert(selected, link) end
  end
  return ok({ pr_links = selected })
end

local function get_pr_link(arguments)
  arguments = arguments or {}
  local link = find_by_id(load_state().pr_links, string_arg(arguments, "pr_link_id"))
  if not link then return failure("not_found", "PR link not found") end
  return ok({ pr_link = link })
end

local function claim_question_orchestrator(arguments, context)
  arguments = arguments or {}
  local state = load_state()
  local scope = string_arg(arguments, "project_id") and "project" or "global"
  local session_uuid = string_arg(arguments, "session_uuid") or string_arg(context or {}, "session_uuid") or "current-session"
  for _, claim in ipairs(state.question_orchestrators) do
    if claim.scope == scope and claim.project_id == arguments.project_id then
      if arguments.replace ~= true and claim.session_uuid ~= session_uuid then return failure("already_claimed", "question orchestrator already claimed") end
      claim.session_uuid = session_uuid
      return persist_response(state, "orchestrator", claim)
    end
  end
  local claim = { id = next_id(state, "question_orchestrator"), scope = scope, project_id = arguments.project_id, session_uuid = session_uuid }
  table.insert(state.question_orchestrators, claim)
  return persist_response(state, "orchestrator", claim)
end

local function release_question_orchestrator(arguments, context)
  arguments = arguments or {}
  local state = load_state()
  local session_uuid = string_arg(arguments, "session_uuid") or string_arg(context or {}, "session_uuid")
  for index = #state.question_orchestrators, 1, -1 do
    local claim = state.question_orchestrators[index]
    if (not session_uuid or claim.session_uuid == session_uuid) and claim.project_id == arguments.project_id then
      table.remove(state.question_orchestrators, index)
      return persist_response(state, "orchestrator", claim)
    end
  end
  return ok({ released = false })
end

local function question_orchestrator_status()
  return ok({ orchestrators = load_state().question_orchestrators })
end

local function ask_question(arguments, context, kind)
  arguments = arguments or {}
  arguments.kind = kind
  arguments.asked_by = arguments.asked_by or string_arg(context or {}, "session_uuid")
  return record_question(arguments)
end

local function ask_human(arguments, context) return ask_question(arguments, context, "human") end
local function ask_agent(arguments, context) return ask_question(arguments, context, "agent") end

local function receive_question_answers(arguments, context)
  arguments = arguments or {}
  local state = load_state()
  local session_uuid = string_arg(arguments, "session_uuid") or string_arg(context or {}, "session_uuid")
  local answers = {}
  for _, answer in ipairs(state.answers) do
    local question = find_by_id(state.questions, answer.question_id)
    if question and (arguments.all == true or not session_uuid or question.asked_by == session_uuid)
      and (not arguments.question_id or question.id == arguments.question_id)
      and (not arguments.run_id or question.run_id == arguments.run_id)
      and (not arguments.ticket_id or question.ticket_id == arguments.ticket_id)
      and (not arguments.status or question.status == arguments.status)
    then table.insert(answers, { question = question, answer = answer }) end
  end
  return ok({ answers = answers })
end

local function escalate_question(arguments)
  arguments = arguments or {}
  local state = load_state()
  local question = find_by_id(state.questions, string_arg(arguments, "question_id"))
  if not question then return failure("not_found", "question not found") end
  question.kind = "human"
  question.status = "open"
  question.escalation_reason = string_arg(arguments, "reason")
  return persist_response(state, "question", question)
end

local function list_agent_choices()
  return ok({ agents = { { name = "codex", label = "codex" }, { name = "claude", label = "claude" } } })
end

local function current_context(arguments)
  arguments = arguments or {}
  local state = load_state()
  local run_id = string_arg(arguments, "run_id")
  local context = {
    projects = state.projects,
    project_targets = state.project_targets,
    tickets = state.tickets,
    ticket_dependencies = state.ticket_dependencies,
    pipeline_definitions = state.pipeline_definitions,
    runs = records_for_run(state.runs, run_id),
    run_steps = records_for_run(state.run_steps, run_id),
    gate_results = records_for_run(state.gate_results, run_id),
    reviews = records_for_run(state.reviews, run_id),
    findings = records_for_run(state.findings, run_id),
    artifacts = records_for_run(state.artifacts, run_id),
    checklists = records_for_run(state.checklists, run_id),
    checklist_items = records_for_run(state.checklist_items, run_id),
    questions = records_for_run(state.questions, run_id),
    answers = records_for_run(state.answers, run_id),
    question_orchestrators = state.question_orchestrators,
    pr_links = records_for_run(state.pr_links, run_id),
    events = records_for_run(state.events, run_id),
    session_requests = records_for_run(state.session_requests, run_id),
    source_revision = SOURCE_REVISION,
    source_authority = "trybotster/botster-project-pipelines:plugin.lua",
  }
  if run_id then
    context.run = find_by_id(state.runs, run_id)
    context.ticket = context.run and find_by_id(state.tickets, context.run.ticket_id) or nil
    context.pipeline = context.run and find_by_id(state.pipeline_definitions, context.run.pipeline_definition_id) or nil
    context.current_step = context.pipeline and find_pipeline_step(context.pipeline, context.run.current_step_id) or nil
    context.current_run_step = context.run and find_by_id(state.run_steps, context.run.current_run_step_id) or nil
  end
  return ok(context)
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

local function start_run_action(arguments)
  local open_result = open_dialog_action(arguments, "project-pipelines.record-run-dialog")
  if open_result then return open_result end
  return action_from_tool(arguments, start_run, {
    field_ids = {
      ticket_id = "project-pipelines-record-run-ticket-id",
      pipeline_definition_id = "project-pipelines-record-run-pipeline-id",
    },
    presentation = {
      { kind = "clear", key = "project-pipelines.record-run-dialog" },
    },
    replacement = function(response)
      local run = response.run or {}
      return {
        type = "text",
        id = "project-pipelines-recorded-run",
        props = {
          text = "Started run " .. tostring(run.id) .. " at step " .. tostring(run.current_step_id or "current"),
        },
      }
    end,
  })
end

local function spawn_ticket_session_action(arguments)
  local open_result = open_dialog_action(arguments, "project-pipelines.activate-step-dialog")
  if open_result then return open_result end
  return action_from_tool(arguments, spawn_ticket_session, {
    field_ids = {
      run_id = "project-pipelines-action-run-id",
      step_id = "project-pipelines-action-step-id",
      session_type_id = "project-pipelines-action-session-type-id",
    },
    presentation = {
      { kind = "clear", key = "project-pipelines.activate-step-dialog" },
    },
    replacement = function(response)
      local activation = response.activation or {}
      local status = activation.status or "spawned"
      local session_type = activation.session_type_id or activation.resolved_session_type_id
      local label = "Agent " .. tostring(status)
      if session_type and tostring(session_type) ~= "" then
        label = label .. " · " .. tostring(session_type)
      end
      local tone = status == "blocked" and "warning" or status == "failed" and "danger" or "success"
      return {
        type = "status_badge",
        id = "project-pipelines-activated-step",
        props = {
          label = label,
          status = status,
          tone = tone,
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
      error = "Choose a filter before applying it.",
      error_code = "validation_failed",
      form_errors = { "Choose a filter before applying it." },
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
      error = "Select a row first.",
      error_code = "validation_failed",
      form_errors = { "Select a row first." },
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
  emit("project_target", context.project_targets)
  emit("ticket", context.tickets)
  emit("ticket_dependency", context.ticket_dependencies)
  emit("pipeline_definition", context.pipeline_definitions)
  emit("run", context.runs)
  emit("run_step", context.run_steps)
  emit("gate_result", context.gate_results)
  emit("review", context.reviews)
  emit("finding", context.findings)
  emit("artifact", context.artifacts)
  emit("checklist", context.checklists)
  emit("checklist_item", context.checklist_items)
  emit("question", context.questions)
  emit("answer", context.answers)
  emit("question_orchestrator", context.question_orchestrators)
  emit("pr_link", context.pr_links)
  emit("event", context.events)
  emit("session_request", context.session_requests)
  return ok({ frames = frames })
end

local ENTITY_PROVIDER_FAMILIES = {
  { family = "project", records = "projects" },
  { family = "project_target", records = "project_targets" },
  { family = "ticket", records = "tickets" },
  { family = "ticket_dependency", records = "ticket_dependencies" },
  { family = "pipeline_definition", records = "pipeline_definitions" },
  { family = "run", records = "runs" },
  { family = "run_step", records = "run_steps" },
  { family = "gate_result", records = "gate_results" },
  { family = "review", records = "reviews" },
  { family = "finding", records = "findings" },
  { family = "artifact", records = "artifacts" },
  { family = "checklist", records = "checklists" },
  { family = "checklist_item", records = "checklist_items" },
  { family = "question", records = "questions" },
  { family = "answer", records = "answers" },
  { family = "question_orchestrator", records = "question_orchestrators" },
  { family = "pr_link", records = "pr_links" },
  { family = "event", records = "events" },
  { family = "session_request", records = "session_requests" },
}

local entity_snapshot_sequences = {}

local function entity_provider_handler(family, records)
  local entity_type = "project-pipelines." .. family
  return function(_request)
    local sequence = (entity_snapshot_sequences[family] or 0) + 1
    entity_snapshot_sequences[family] = sequence
    return {
      type = "entity_snapshot",
      entity_type = entity_type,
      snapshot_seq = sequence,
      items = load_state()[records],
    }
  end
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

-- Operator-facing status presentation. Nested helpers stay off the main local budget.
local function human_status_label(status)
  local labels = {
    spawn_requested = "spawn requested",
    ready_for_review = "ready for review",
    waiting = "waiting",
    blocked = "blocked",
    failed = "failed",
    active = "running",
    open = "open",
    closed = "closed",
    question = "question",
    available = "available",
    review = "in review",
    ready = "ready",
  }
  if status == nil or status == "" then return "unknown" end
  return labels[status] or tostring(status):gsub("_", " ")
end

local function list_item(id, title, subtitle, status)
  local tone = "muted"
  if status == "failed" then
    tone = "danger"
  elseif status == "blocked" or status == "waiting" or status == "question" then
    tone = "warning"
  elseif status == "spawn_requested" or status == "active" or status == "running" then
    tone = "accent"
  elseif status == "ready_for_review" or status == "review" or status == "ready" or status == "available" then
    tone = "success"
  end
  local label = human_status_label(status)
  return {
    type = "list_item",
    id = id,
    props = { value = id },
    slots = {
      title = { text_node(id .. "-title", title) },
      subtitle = {
        inline_node(id .. "-subtitle", {
          text_node(id .. "-subtitle-text", subtitle),
          status_badge_node(id .. "-status", label, status or "unknown", tone),
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

local function step_label(context, run, step_id)
  if step_id == nil or step_id == "" then return "current step" end
  local pipeline = run and pipeline_for_run(context, run) or nil
  local step = nil
  if type(pipeline) == "table" then
    for _, candidate in ipairs(pipeline.steps or {}) do
      if candidate.id == step_id then
        step = candidate
        break
      end
    end
  end
  if step and type(step.name) == "string" and step.name ~= "" then return step.name end
  return tostring(step_id)
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
    if type(run.blocked_transition) == "table" or type(run.waiting_transition) == "table" then
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
        button_node("project-pipelines-toolbar-record-run", "Start run", "project_pipelines.start_run", { intent = "open_dialog" }),
      },
      filters = {
        button_node("project-pipelines-toolbar-filter-attention", "Needs attention", "project_pipelines.filter", { status = "attention" }, "warning"),
        button_node("project-pipelines-toolbar-filter-running", "Running", "project_pipelines.filter", { status = "active" }, "accent"),
        button_node("project-pipelines-toolbar-filter-review", "Ready for review", "project_pipelines.filter", { status = "review" }, "success"),
      },
      actions = {
        button_node("project-pipelines-toolbar-activate-step", "Spawn agent", "project_pipelines.spawn_ticket_session", { intent = "open_dialog" }),
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

local function list_section(id, title, empty_title, empty_description, items)
  local children = items
  if #items == 0 then
    children = {
      {
        type = "empty_state",
        id = id .. "-empty",
        props = {
          title = empty_title,
          description = empty_description or "Nothing to show right now.",
        },
      },
    }
  end
  return section_node(id, title, nil, { list_node(id .. "-list", children) })
end

-- One description for a durable hold, so the attention queue and the runs table agree on
-- why a run is parked whether it waits on dependencies or on lapsed authorization.
-- Returns the descriptive clause and the same reasons as discrete labels.
local function hold_reason(context, blocked)
  local labels = {}
  for _, dependency in ipairs(array(blocked.unmet_dependencies)) do
    local dependency_ticket = find_by_id(context.tickets, dependency.dependency_ticket_id)
    table.insert(labels, dependency_ticket and dependency_ticket.title or dependency.dependency_ticket_id)
  end
  if #labels > 0 then return "for " .. table.concat(labels, ", "), labels end
  for _, blocker in ipairs(array(blocked.unmet_authorization)) do
    local subject = blocker.gate_id or blocker.finding_id or blocker.review_id or blocker.current_step_id
    table.insert(labels, subject and (tostring(blocker.kind) .. " " .. tostring(subject)) or tostring(blocker.kind))
  end
  if #labels > 0 then return "until authorization is restored: " .. table.concat(labels, ", "), labels end
  return "with no recorded blockers", labels
end

local function attention_items(context)
  local items = {}
  for _, run in ipairs(context.runs) do
    local blocked = run.waiting_transition or run.blocked_transition
    -- Select on the durable hold record itself, the same predicate status_summary counts,
    -- so the queue and the needs-attention metric cannot disagree. Keying on a single code
    -- string silently dropped authorization holds, which are exactly the ones needing a human.
    if type(blocked) == "table" then
      local ticket = ticket_for_run(context, run)
      local step_id = blocked.target_step_id or blocked.step_id
      local reason, _ = hold_reason(context, blocked)
      table.insert(items, list_item(
        "project-pipelines-attention-dependencies-" .. run.id,
        ticket and ticket.title or run.ticket_id,
        "Waiting before " .. step_label(context, run, step_id) .. " " .. reason,
        run.waiting_transition and "waiting" or "blocked"
      ))
    end
  end
  for _, request in ipairs(context.session_requests) do
    if request.status == "blocked" or request.status == "failed" then
      local ticket = find_by_id(context.tickets, request.ticket_id)
      local run = find_by_id(context.runs, request.run_id)
      local diagnostic = request.diagnostic or (request.result and request.result.error) or {}
      local status = request.status == "failed" and "failed" or "blocked"
      local parts = {}
      local step_name = step_label(context, run, request.step_id)
      if request.step_id then table.insert(parts, step_name) end
      if request.session_type_id and tostring(request.session_type_id) ~= "" then
        table.insert(parts, "session type " .. tostring(request.session_type_id))
      end
      local detail = diagnostic.message or request.prompt_summary or "Agent spawn needs attention"
      if #parts > 0 then detail = table.concat(parts, " · ") .. " — " .. detail end
      table.insert(items, list_item(
        "project-pipelines-attention-session-" .. request.id,
        ticket and ticket.title or request.ticket_id or request.id,
        detail,
        status
      ))
    end
  end
  for _, question in ipairs(context.questions) do
    if question.status == "open" or question.status == nil then
      local run = find_by_id(context.runs, question.run_id)
      local ticket = run and ticket_for_run(context, run) or find_by_id(context.tickets, question.ticket_id)
      local scope = ticket and ticket.title or ("run " .. tostring(question.run_id))
      table.insert(items, list_item(
        "project-pipelines-attention-question-" .. question.id,
        question.question,
        "Open question on " .. scope,
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
      local blocked = run.waiting_transition or run.blocked_transition
      local step_id = type(blocked) == "table" and (blocked.target_step_id or blocked.step_id) or run.current_step_id
      local pipeline_name = pipeline and pipeline.name or run.pipeline_definition_id
      table.insert(items, list_item(
        "project-pipelines-running-" .. run.id,
        ticket and ticket.title or run.id,
        tostring(pipeline_name) .. " · " .. step_label(context, run, step_id),
        run.waiting_transition and "waiting" or (type(blocked) == "table" and "blocked" or run.status)
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
        "At " .. step_label(context, run, run.current_step_id),
        run.status
      ))
    end
  end
  return items
end

local bound_list

local function run_status_label(run)
  if type(run.waiting_transition) == "table" then return "waiting" end
  if type(run.blocked_transition) == "table" then return "blocked" end
  return run.status or "unknown"
end

local function project_rows(context)
  local rows = {}
  for _, project in ipairs(context.projects) do
    local row = {
      id = project.id,
      cells = {
        name = project.name,
        mode = project.mode or "standalone",
        spawn_target = project.spawn_target_id or "—",
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
        status = human_status_label(ticket.status or "open"),
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
    local blocked = run.waiting_transition or run.blocked_transition
    local blockers = {}
    if type(blocked) == "table" then
      local _, labels = hold_reason(context, blocked)
      blockers = labels
    end
    local step_id = type(blocked) == "table" and (blocked.target_step_id or blocked.step_id) or run.current_step_id
    table.insert(rows, {
      id = run.id,
      cells = {
        ticket = ticket and ticket.title or run.ticket_id,
        pipeline = pipeline and pipeline.name or run.pipeline_definition_id,
        step = step_label(context, run, step_id),
        blocker = table.concat(blockers, ", "),
        status = human_status_label(run_status_label(run)),
      },
    })
  end
  return rows
end

local function session_request_rows(context)
  local rows = {}
  for _, request in ipairs(context.session_requests) do
    local ticket = find_by_id(context.tickets, request.ticket_id)
    local run = find_by_id(context.runs, request.run_id)
    table.insert(rows, {
      id = request.id,
      cells = {
        ticket = ticket and ticket.title or request.ticket_id or request.id,
        step = step_label(context, run, request.step_id),
        session_type = request.session_type_id or "—",
        status = human_status_label(request.status or "unknown"),
      },
    })
  end
  return rows
end

local function table_node(id, columns, rows, empty_title, empty_description)
  local props = {
    columns = columns,
    selection = { mode = "single" },
    empty_state = {
      type = "empty_state",
      id = id .. "-empty",
      props = {
        title = empty_title,
        description = empty_description or "Create work from the toolbar to fill this table.",
      },
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
      action = { id = "project_pipelines.spawn_ticket_session" },
      submit_label = "Spawn agent",
    },
    children = {
      {
        type = "form_section",
        id = "project-pipelines-action-feedback-section",
        props = {
          title = "Spawn agent",
          description = "Starts a Hub session for a run step. Session type comes from the form override, the step, or the package default.",
        },
        children = {
          {
            type = "form_field",
            id = "project-pipelines-action-run-id",
            props = {
              schema = {
                kind = "text",
                name = "run_id",
                label = "Run",
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
                label = "Step",
                required = false,
                description = "Optional. Defaults to the run's current step.",
              },
            },
          },
          {
            type = "form_field",
            id = "project-pipelines-action-session-type-id",
            props = {
              schema = {
                kind = "text",
                name = "session_type_id",
                label = "Session type",
                required = false,
                description = "Optional Hub session type id. Leave blank to use the step or package default.",
              },
            },
          },
          button_node("project-pipelines-action-submit", "Spawn agent", "project_pipelines.spawn_ticket_session", {}, "accent"),
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
          text_input_node("project-pipelines-create-ticket-project-id", "project_id", "Project", true),
          text_input_node("project-pipelines-create-ticket-title", "title", "Ticket title", true),
        }
      )
    ),
    presentation_dialog(
      "project-pipelines.record-run-dialog",
      "project-pipelines-record-run-dialog",
      "Start run",
      dialog_form(
        "project-pipelines-record-run-form",
        "project_pipelines.start_run",
        "Start run",
        {
          text_input_node("project-pipelines-record-run-ticket-id", "ticket_id", "Ticket", true),
          text_input_node("project-pipelines-record-run-pipeline-id", "pipeline_definition_id", "Pipeline", true),
        }
      )
    ),
    presentation_dialog(
      "project-pipelines.activate-step-dialog",
      "project-pipelines-activate-step-dialog",
      "Spawn agent",
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
          "Selected workspace: " .. project.name
        ),
      })
    end
  end
  return children
end

local function drilldown_tables(context)
  return section_node(
    "project-pipelines-workbench",
    "Records",
    "Projects, tickets, runs, and agent spawns. Select a workspace-linked project to focus it.",
    {
    table_node(
      "project-pipelines-project-table",
      {
        { id = "name", label = "Project" },
        { id = "mode", label = "Mode" },
        { id = "spawn_target", label = "Spawn point" },
      },
      project_rows(context),
      "No projects yet",
      "Create a project with the Project Pipelines tools, then create tickets here."
    ),
    table_node(
      "project-pipelines-ticket-table",
      {
        { id = "title", label = "Ticket" },
        { id = "project", label = "Project" },
        { id = "status", label = "Status" },
      },
      ticket_rows(context),
      "No tickets yet",
      "Use Create ticket to open work under a project."
    ),
    table_node(
      "project-pipelines-run-table",
      {
        { id = "ticket", label = "Ticket" },
        { id = "pipeline", label = "Pipeline" },
        { id = "step", label = "Step" },
        { id = "blocker", label = "Blocked by" },
        { id = "status", label = "Status" },
      },
      run_rows(context),
      "No runs yet",
      "Use Start run to begin a pipeline on a ticket."
    ),
    table_node(
      "project-pipelines-session-request-table",
      {
        { id = "ticket", label = "Ticket" },
        { id = "step", label = "Step" },
        { id = "session_type", label = "Session type" },
        { id = "status", label = "Status" },
      },
      session_request_rows(context),
      "No agent spawns yet",
      "Use Spawn agent on a run step. Hub owns the session type launch contract."
    ),
  })
end

local function entity_stream_section()
  return section_node(
    "project-pipelines-entity-streams",
    "Live records",
    "Hosts bind these lists to plugin entity frames for live refresh. Prefer the tables above for day-to-day work.",
    {
    list_node("project-pipelines-workbench-lists", {
      bound_list("project-pipelines-project-list", "project-pipelines.project", "No projects"),
      bound_list("project-pipelines-ticket-list", "project-pipelines.ticket", "No tickets"),
      bound_list("project-pipelines-run-list", "project-pipelines.run", "No runs"),
      bound_list("project-pipelines-session-request-list", "project-pipelines.session_request", "No agent spawns"),
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
    return "Provider dependencies are available for recorded agent spawns."
  end
  local first = status.blocked[1] or {}
  local label = first.dependency or first.capability or "provider dependency"
  if first.provider then label = first.provider .. ":" .. label end
  return "Provider dependency blocked: " .. label .. ". Fix the provider, then retry Spawn agent."
end

local function settings_readiness(context, provider_status)
  local summary = status_summary(context)
  local items = {}
  table.insert(items, list_item(
    "project-pipelines-readiness-storage",
    "Plugin database",
    "Workflow state is stored in the package database.",
    "available"
  ))
  table.insert(items, list_item(
    "project-pipelines-readiness-provider-dependencies",
    "Provider dependencies",
    provider_status_text(provider_status),
    provider_status.status
  ))
  local session_status = "available"
  local session_subtitle = "Session types are ready for agent spawns."
  if summary.failed_sessions > 0 then
    session_status = "failed"
    local n = summary.failed_sessions
    session_subtitle = tostring(n) .. (n == 1 and " agent spawn failed." or " agent spawns failed.")
  elseif summary.blocked_sessions > 0 then
    session_status = "blocked"
    local n = summary.blocked_sessions
    session_subtitle = tostring(n) .. (n == 1 and " agent spawn is blocked." or " agent spawns are blocked.")
  end
  table.insert(items, list_item(
    "project-pipelines-readiness-session-types",
    "Session types",
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
      props = {
        title = empty_title,
        description = "Live rows appear here after hosts subscribe to entity frames.",
      },
    },
  }
end

local function render_home()
  local context = current_context()
  local summary = status_summary(context)
  local children = {
      panel_node("project-pipelines-command-center", "Overview", {
        toolbar_node("project-pipelines-workbench-toolbar"),
        metric_grid_node("project-pipelines-command-center-metrics", {
          metric_node("project-pipelines-metric-attention", "Needs attention", summary.needs_attention, summary.needs_attention > 0 and "warning" or "default", "Blocked steps, failed spawns, open questions", summary.needs_attention > 0 and "needs_attention" or "clear"),
          metric_node("project-pipelines-metric-running", "Running", summary.active_runs, "accent", "Active pipeline runs", "active"),
          metric_node("project-pipelines-metric-review", "Ready for review", summary.review_runs, "success", "Review or merge queue", "ready"),
          metric_node("project-pipelines-metric-open-tickets", "Open tickets", summary.open_tickets, "muted", "Tickets still open", "open"),
        }),
      }),
      list_section(
        "project-pipelines-needs-attention",
        "Needs attention",
        "All clear",
        "No blocked steps, failed agent spawns, or open questions.",
        attention_items(context)
      ),
      list_section(
        "project-pipelines-running",
        "Running",
        "Nothing running",
        "Start a run to see active pipeline work here.",
        running_items(context)
      ),
      list_section(
        "project-pipelines-ready-for-review",
        "Ready for review",
        "Nothing waiting for review",
        "Runs that are ready for review appear here.",
        review_items(context)
      ),
      section_node(
        "project-pipelines-create-guidance",
        "Common path",
        "Day-to-day operator loop. Advanced tools remain available through MCP.",
        {
          text_node(
            "project-pipelines-create-guidance-summary",
            "Create a ticket, start a run, then spawn an agent on the current step. Session types are Hub launch contracts; this package does not invent a second launch system."
          ),
          list_node("project-pipelines-create-guidance-actions", {
            list_item("project-pipelines-create-project-action", "Create project", "Group tickets and set a default spawn point", "tool"),
            list_item("project-pipelines-create-ticket-action", "Create ticket", "Open work under a project", "tool"),
            list_item("project-pipelines-define-pipeline-action", "Create pipeline", "Define ordered steps and gates", "tool"),
            list_item("project-pipelines-record-run-action", "Start run", "Begin a pipeline on a ticket", "tool"),
            list_item("project-pipelines-activate-step-action", "Spawn agent", "Launch a Hub session type for the step", "tool"),
          }),
        }
      ),
      drilldown_tables(context),
      entity_stream_section(),
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
        metric_node("project-pipelines-settings-count-sessions", "Agent spawns", #context.session_requests, "muted"),
        metric_node("project-pipelines-settings-count-open-questions", "Open questions", summary.open_questions, summary.open_questions > 0 and "warning" or "muted"),
      }),
      panel_node("project-pipelines-readiness", "Readiness", {
        list_node("project-pipelines-readiness-list", settings_readiness(context, provider_status)),
      }),
      text_node("project-pipelines-settings-storage", "Workflow state is stored in the package database."),
      panel_node("project-pipelines-provider-dependency-status", "Provider dependencies", {
        text_node("project-pipelines-provider-dependency-status-summary", provider_status_text(provider_status)),
        badge_node("project-pipelines-provider-dependency-status-badge", provider_status.status .. ": " .. tostring(provider_status.blocked_count), provider_status.status == "blocked" and "warning" or "success"),
      }),
      panel_node("project-pipelines-settings-defaults", "Defaults", {
        text_node(
          "project-pipelines-settings-defaults-summary",
          "Package defaults cover spawn point, session type, pipeline mode, and optional workspace link. Reload the package after changes. Standalone projects stay valid without a workspace."
        ),
        list_node("project-pipelines-settings-default-fields", {
          list_item("project-pipelines-settings-default-spawn-target", "Default spawn point", "default_spawn_target_id", "config"),
          list_item("project-pipelines-settings-default-session-type", "Default session type", "default_session_type_id", "config"),
          list_item("project-pipelines-settings-default-pipeline-mode", "Default pipeline mode", "default_pipeline_mode", "config"),
          list_item("project-pipelines-settings-workspace-id", "Workspace", "workspace_id", "config"),
        }),
      }),
    })
end

local TOOL_CONTRACTS = {
  ["add_artifact"] = {
    ["description"] = "Attach a durable artifact to a run, such as a plan, patch summary, command result, or external URL.",
    ["input_schema"] = {
      ["properties"] = {
        ["kind"] = {
          ["type"] = "string",
        },
        ["payload"] = {
          ["type"] = "object",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["run_step_id"] = {
          ["type"] = "string",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
        ["summary"] = {
          ["type"] = "string",
        },
        ["uri"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "run_id",
      },
      ["type"] = "object",
    },
  },
  ["add_checklist_item"] = {
    ["description"] = "Add a checkpoint to an existing checklist.",
    ["input_schema"] = {
      ["properties"] = {
        ["checklist_id"] = {
          ["type"] = "string",
        },
        ["evidence"] = {
          ["type"] = "object",
        },
        ["position"] = {
          ["type"] = "integer",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["source_ref"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "pending",
            "in_progress",
            "blocked",
            "skipped",
            "done",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "checklist_id",
        "prompt",
      },
      ["type"] = "object",
    },
  },
  ["add_project_target"] = {
    ["description"] = "Attach a spawn target to a project.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_id"] = {
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "project_id",
        "target_id",
      },
      ["type"] = "object",
    },
  },
  ["add_ticket_dependency"] = {
    ["description"] = "Add an ordering dependency. The ticket cannot start a pipeline run until the dependency ticket is closed.",
    ["input_schema"] = {
      ["properties"] = {
        ["depends_on_ticket_id"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
        "depends_on_ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["answer_question"] = {
    ["description"] = "Answer a Project Pipelines question and notify the asking session to read the durable answer with project_pipelines_receive_question_answers.",
    ["input_schema"] = {
      ["properties"] = {
        ["answer"] = {
          ["type"] = "string",
        },
        ["question_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "answered",
            "dismissed",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "question_id",
        "answer",
      },
      ["type"] = "object",
    },
  },
  ["ask_agent"] = {
    ["description"] = "Ask a new or configured advisor agent a durable pipeline question.",
    ["input_schema"] = {
      ["properties"] = {
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["blocking"] = {
          ["type"] = "boolean",
        },
        ["question"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
        ["workspace_name"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "question",
      },
      ["type"] = "object",
    },
  },
  ["ask_human"] = {
    ["description"] = "Ask a durable pipeline question. It routes to the active project/global question orchestrator first and falls back to the human when none is active.",
    ["input_schema"] = {
      ["properties"] = {
        ["blocking"] = {
          ["type"] = "boolean",
        },
        ["question"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "question",
      },
      ["type"] = "object",
    },
  },
  ["cancel_run"] = {
    ["description"] = "Cancel an active or blocked pipeline run without advancing steps or requesting a merge. This marks the current step cancelled and closes agents owned by the run.",
    ["input_schema"] = {
      ["properties"] = {
        ["reason"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "run_id",
      },
      ["type"] = "object",
    },
  },
  ["checklist_instructions"] = {
    ["description"] = "Return instructions for using Project Pipelines checklists with the vault as the source of truth for conventions.",
    ["input_schema"] = {
      ["properties"] = {},
      ["type"] = "object",
    },
  },
  ["claim_question_orchestrator"] = {
    ["description"] = "Claim ownership of answering Project Pipelines questions from the calling agent session. Omit project_id to become the global fallback; provide it to own one project. This does not require the agent to belong to a ticket.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_id"] = {
          ["type"] = "string",
        },
        ["replace"] = {
          ["description"] = "Replace another active owner. Inactive owners are replaced automatically.",
          ["type"] = "boolean",
        },
      },
      ["type"] = "object",
    },
  },
  ["close_ticket"] = {
    ["description"] = "Close a ticket. Completed pipeline work requires merge_confirmed=true. PR-policy tickets close only after Project Pipelines has a linked merged PR, normally from a provider pr_merged event. When merge_confirmed is true, include merge_commit, pr_url, or merge_summary when available so the ticket keeps a merge artifact.",
    ["input_schema"] = {
      ["properties"] = {
        ["base_branch"] = {
          ["type"] = "string",
        },
        ["merge_commit"] = {
          ["type"] = "string",
        },
        ["merge_confirmed"] = {
          ["type"] = "boolean",
        },
        ["merge_summary"] = {
          ["type"] = "string",
        },
        ["pr_url"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["create_checklist"] = {
    ["description"] = "Create a durable checklist for a project, ticket, or run. Use prompts as workflow checkpoints; keep project conventions in the vault and attach evidence that they were read/applied.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["items"] = {
          ["items"] = {
            ["properties"] = {
              ["evidence"] = {
                ["type"] = "object",
              },
              ["id"] = {
                ["type"] = "string",
              },
              ["position"] = {
                ["type"] = "integer",
              },
              ["prompt"] = {
                ["type"] = "string",
              },
              ["source_ref"] = {
                ["type"] = "string",
              },
              ["status"] = {
                ["enum"] = {
                  "pending",
                  "in_progress",
                  "blocked",
                  "skipped",
                  "done",
                },
                ["type"] = "string",
              },
            },
            ["required"] = {
              "prompt",
            },
            ["type"] = "object",
          },
          ["type"] = "array",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["owner_id"] = {
          ["type"] = "string",
        },
        ["scope"] = {
          ["enum"] = {
            "project",
            "ticket",
            "run",
          },
          ["type"] = "string",
        },
        ["source"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "scope",
        "owner_id",
        "name",
      },
      ["type"] = "object",
    },
  },
  ["create_child_run"] = {
    ["description"] = "Create a child ticket and pipeline run for a slice of a larger parent run.",
    ["input_schema"] = {
      ["properties"] = {
        ["base_ref"] = {
          ["type"] = "string",
        },
        ["base_run_id"] = {
          ["type"] = "string",
        },
        ["base_target_path"] = {
          ["type"] = "string",
        },
        ["base_ticket_id"] = {
          ["type"] = "string",
        },
        ["description"] = {
          ["type"] = "string",
        },
        ["parent_run_id"] = {
          ["type"] = "string",
        },
        ["pipeline_id"] = {
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
        ["title"] = {
          ["type"] = "string",
        },
        ["workspace_id"] = {
          ["type"] = "string",
        },
        ["workspace_name"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "parent_run_id",
        "title",
      },
      ["type"] = "object",
    },
  },
  ["create_gate"] = {
    ["description"] = "Create a gate under an existing pipeline step.",
    ["input_schema"] = {
      ["properties"] = {
        ["command"] = {
          ["type"] = "string",
        },
        ["id"] = {
          ["type"] = "string",
        },
        ["kind"] = {
          ["enum"] = {
            "attestation",
            "review_clear",
            "command",
          },
          ["type"] = "string",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["required_fields"] = {
          ["items"] = {
            ["type"] = "string",
          },
          ["type"] = "array",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "step_id",
        "prompt",
      },
      ["type"] = "object",
    },
  },
  ["create_pipeline"] = {
    ["description"] = "Create a project pipeline definition. Agents use this to define reusable ticket pipelines explicitly; Botster does not seed default pipelines.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["id"] = {
          ["type"] = "string",
        },
        ["merge_policy"] = {
          ["enum"] = {
            "direct",
            "pr",
          },
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["replacement_pipeline_id"] = {
          ["type"] = "string",
        },
        ["steps"] = {
          ["items"] = {
            ["properties"] = {
              ["agent_name"] = {
                ["type"] = "string",
              },
              ["command"] = {
                ["type"] = "string",
              },
              ["gates"] = {
                ["items"] = {
                  ["properties"] = {
                    ["command"] = {
                      ["type"] = "string",
                    },
                    ["id"] = {
                      ["type"] = "string",
                    },
                    ["kind"] = {
                      ["enum"] = {
                        "attestation",
                        "review_clear",
                        "command",
                      },
                      ["type"] = "string",
                    },
                    ["prompt"] = {
                      ["type"] = "string",
                    },
                    ["required_fields"] = {
                      ["items"] = {
                        ["type"] = "string",
                      },
                      ["type"] = "array",
                    },
                  },
                  ["required"] = {
                    "prompt",
                  },
                  ["type"] = "object",
                },
                ["type"] = "array",
              },
              ["id"] = {
                ["type"] = "string",
              },
              ["kind"] = {
                ["enum"] = {
                  "agent",
                  "command",
                  "pty",
                  "session",
                  "session_type",
                },
                ["type"] = "string",
              },
              ["name"] = {
                ["type"] = "string",
              },
              ["next_step_id"] = {
                ["type"] = "string",
              },
              ["on_approved_step_id"] = {
                ["type"] = "string",
              },
              ["on_blocked_step_id"] = {
                ["type"] = "string",
              },
              ["on_changes_requested_step_id"] = {
                ["type"] = "string",
              },
              ["position"] = {
                ["type"] = "integer",
              },
              ["prompt"] = {
                ["type"] = "string",
              },
              ["required_provider_dependencies"] = {
                ["items"] = {
                  ["oneOf"] = {
                    {
                      ["type"] = "string",
                    },
                    {
                      ["properties"] = {
                        ["capability"] = {
                          ["type"] = "string",
                        },
                        ["dependency"] = {
                          ["type"] = "string",
                        },
                        ["provider"] = {
                          ["type"] = "string",
                        },
                      },
                      ["required"] = {
                        "dependency",
                      },
                      ["type"] = "object",
                    },
                  },
                },
                ["type"] = "array",
              },
              ["session_type_id"] = {
                ["type"] = "string",
              },
            },
            ["required"] = {
              "name",
            },
            ["type"] = "object",
          },
          ["type"] = "array",
        },
        ["supersedes_pipeline_id"] = {
          ["type"] = "string",
        },
        ["version_label"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "id",
        "name",
        "steps",
      },
      ["type"] = "object",
    },
  },
  ["create_project"] = {
    ["description"] = "Create an optional project for multi-phase or coordinated work.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "name",
      },
      ["type"] = "object",
    },
  },
  ["create_step"] = {
    ["description"] = "Create a step in an existing pipeline definition.",
    ["input_schema"] = {
      ["properties"] = {
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["command"] = {
          ["type"] = "string",
        },
        ["gates"] = {
          ["items"] = {
            ["properties"] = {
              ["command"] = {
                ["type"] = "string",
              },
              ["id"] = {
                ["type"] = "string",
              },
              ["kind"] = {
                ["enum"] = {
                  "attestation",
                  "review_clear",
                  "command",
                },
                ["type"] = "string",
              },
              ["prompt"] = {
                ["type"] = "string",
              },
              ["required_fields"] = {
                ["items"] = {
                  ["type"] = "string",
                },
                ["type"] = "array",
              },
            },
            ["required"] = {
              "prompt",
            },
            ["type"] = "object",
          },
          ["type"] = "array",
        },
        ["id"] = {
          ["type"] = "string",
        },
        ["kind"] = {
          ["enum"] = {
            "agent",
            "command",
          },
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["next_step_id"] = {
          ["type"] = "string",
        },
        ["on_approved_step_id"] = {
          ["type"] = "string",
        },
        ["on_blocked_step_id"] = {
          ["type"] = "string",
        },
        ["on_changes_requested_step_id"] = {
          ["type"] = "string",
        },
        ["pipeline_id"] = {
          ["type"] = "string",
        },
        ["position"] = {
          ["type"] = "integer",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "pipeline_id",
        "name",
      },
      ["type"] = "object",
    },
  },
  ["create_ticket"] = {
    ["description"] = "Create a project pipeline ticket. target_id identifies the spawn target; its filesystem path is resolved automatically and is never set by callers.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["project_id"] = {
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
        ["title"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "title",
        "target_id",
      },
      ["type"] = "object",
    },
  },
  ["create_vault_checklist"] = {
    ["description"] = "Create the standard vault workflow checklist for a project, ticket, or run without copying vault conventions into the pipeline.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["owner_id"] = {
          ["type"] = "string",
        },
        ["scope"] = {
          ["enum"] = {
            "project",
            "ticket",
            "run",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "owner_id",
      },
      ["type"] = "object",
    },
  },
  ["current_context"] = {
    ["description"] = "Return ticket, run, current step, gate prompts, reviews, findings, artifacts, dependencies, questions, and events for the current pipeline run. If run_id is omitted, infer it from the calling agent session.",
    ["input_schema"] = {
      ["properties"] = {
        ["run_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["delete_gate"] = {
    ["description"] = "Delete a pipeline gate that has no submitted gate results.",
    ["input_schema"] = {
      ["properties"] = {
        ["gate_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "gate_id",
      },
      ["type"] = "object",
    },
  },
  ["delete_pipeline"] = {
    ["description"] = "Delete a pipeline definition that has no run history. Steps and gates are deleted with it.",
    ["input_schema"] = {
      ["properties"] = {
        ["pipeline_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "pipeline_id",
      },
      ["type"] = "object",
    },
  },
  ["delete_project"] = {
    ["description"] = "Delete a project that has no tickets. Project spawn-target rows are deleted with it.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "project_id",
      },
      ["type"] = "object",
    },
  },
  ["delete_step"] = {
    ["description"] = "Delete a pipeline step that has no run history. Gates under the step are deleted with it.",
    ["input_schema"] = {
      ["properties"] = {
        ["step_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "step_id",
      },
      ["type"] = "object",
    },
  },
  ["delete_ticket"] = {
    ["description"] = "Delete a ticket that has no run history.",
    ["input_schema"] = {
      ["properties"] = {
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["escalate_question"] = {
    ["description"] = "Escalate an open question assigned to the calling orchestrator back to the human without answering it.",
    ["input_schema"] = {
      ["properties"] = {
        ["question_id"] = {
          ["type"] = "string",
        },
        ["reason"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "question_id",
      },
      ["type"] = "object",
    },
  },
  ["get_checklist"] = {
    ["description"] = "Get one checklist with ordered checklist items and their evidence.",
    ["input_schema"] = {
      ["properties"] = {
        ["checklist_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "checklist_id",
      },
      ["type"] = "object",
    },
  },
  ["get_pipeline"] = {
    ["description"] = "Get one project pipeline definition with ordered steps and gates. Archived pipelines require include_archived=true.",
    ["input_schema"] = {
      ["properties"] = {
        ["include_archived"] = {
          ["type"] = "boolean",
        },
        ["pipeline_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "pipeline_id",
      },
      ["type"] = "object",
    },
  },
  ["get_pr_link"] = {
    ["description"] = "Get a linked pull request by Project Pipelines PR link id.",
    ["input_schema"] = {
      ["properties"] = {
        ["pr_link_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "pr_link_id",
      },
      ["type"] = "object",
    },
  },
  ["get_project"] = {
    ["description"] = "Get one project with its tickets and spawn targets.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "project_id",
      },
      ["type"] = "object",
    },
  },
  ["get_ticket"] = {
    ["description"] = "Get one ticket with its project, runs, current status, run steps, sessions, and open findings.",
    ["input_schema"] = {
      ["properties"] = {
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["link_pr"] = {
    ["description"] = "Link a provider pull request to a ticket so provider-neutral pr_merged events can close the ticket after merge.",
    ["input_schema"] = {
      ["properties"] = {
        ["base_branch"] = {
          ["type"] = "string",
        },
        ["head_branch"] = {
          ["type"] = "string",
        },
        ["pr_number"] = {
          ["type"] = "integer",
        },
        ["pr_url"] = {
          ["type"] = "string",
        },
        ["provider"] = {
          ["default"] = "github",
          ["type"] = "string",
        },
        ["repo"] = {
          ["description"] = "Repository name such as owner/repo.",
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "open",
            "closed",
            "merged",
          },
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
        "repo",
        "pr_number",
      },
      ["type"] = "object",
    },
  },
  ["list_agent_choices"] = {
    ["description"] = "List available Botster agent definitions for assigning pipeline steps. Pass target_id to include agents configured under that target's repo.",
    ["input_schema"] = {
      ["properties"] = {
        ["target_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["list_checklists"] = {
    ["description"] = "List checklists, optionally filtered by project, ticket, or run owner.",
    ["input_schema"] = {
      ["properties"] = {
        ["owner_id"] = {
          ["type"] = "string",
        },
        ["scope"] = {
          ["enum"] = {
            "project",
            "ticket",
            "run",
          },
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["list_pipelines"] = {
    ["description"] = "List available project pipelines with ordered steps and gate prompts. Archived pipelines are hidden unless include_archived is true.",
    ["input_schema"] = {
      ["properties"] = {
        ["include_archived"] = {
          ["type"] = "boolean",
        },
      },
      ["type"] = "object",
    },
  },
  ["list_pr_links"] = {
    ["description"] = "List pull requests linked to pipeline tickets or runs.",
    ["input_schema"] = {
      ["properties"] = {
        ["provider"] = {
          ["type"] = "string",
        },
        ["repo"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "open",
            "closed",
            "merged",
          },
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["list_projects"] = {
    ["description"] = "List project pipeline projects.",
    ["input_schema"] = {
      ["properties"] = {},
      ["type"] = "object",
    },
  },
  ["list_ticket_dependencies"] = {
    ["description"] = "List ordering dependencies for a ticket, including whether dependency tickets are still open.",
    ["input_schema"] = {
      ["properties"] = {
        ["blocking_only"] = {
          ["type"] = "boolean",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["list_tickets"] = {
    ["description"] = "List project pipeline tickets.",
    ["input_schema"] = {
      ["properties"] = {},
      ["type"] = "object",
    },
  },
  ["question_orchestrator_status"] = {
    ["description"] = "List project and global question-orchestrator assignments and whether each assigned session is currently active.",
    ["input_schema"] = {
      ["properties"] = {},
      ["type"] = "object",
    },
  },
  ["receive_question_answers"] = {
    ["description"] = "Return durable answers for Project Pipelines questions asked by the calling session, optionally filtered by ticket, run, question, or status.",
    ["input_schema"] = {
      ["properties"] = {
        ["all"] = {
          ["type"] = "boolean",
        },
        ["question_id"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "answered",
            "dismissed",
          },
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["release_question_orchestrator"] = {
    ["description"] = "Release the calling session's project-specific or global question-orchestrator claim.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["remove_project_target"] = {
    ["description"] = "Remove one spawn target row from a project.",
    ["input_schema"] = {
      ["properties"] = {
        ["project_target_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "project_target_id",
      },
      ["type"] = "object",
    },
  },
  ["remove_ticket_dependency"] = {
    ["description"] = "Remove a ticket ordering dependency.",
    ["input_schema"] = {
      ["properties"] = {
        ["dependency_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "dependency_id",
      },
      ["type"] = "object",
    },
  },
  ["request_merge"] = {
    ["description"] = "Spawn a merge agent for a ticket whose latest run is complete.",
    ["input_schema"] = {
      ["properties"] = {
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["strategy"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
        ["workspace_name"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["request_step_advance"] = {
    ["description"] = "Ask the pipeline engine to move the current step forward. Returns unmet gate prompts when advancement is blocked. Pass next_step_id to route to a specific step; if gates are unmet, override_unmet_gates=true and override_reason are required.",
    ["input_schema"] = {
      ["properties"] = {
        ["evidence"] = {
          ["type"] = "object",
        },
        ["next_step_id"] = {
          ["type"] = "string",
        },
        ["override_reason"] = {
          ["type"] = "string",
        },
        ["override_unmet_gates"] = {
          ["type"] = "boolean",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["summary"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["resolve_finding"] = {
    ["description"] = "Mark a review finding resolved or waived with a resolution note.",
    ["input_schema"] = {
      ["properties"] = {
        ["finding_id"] = {
          ["type"] = "string",
        },
        ["resolution"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "resolved",
            "waived",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "finding_id",
        "resolution",
      },
      ["type"] = "object",
    },
  },
  ["retry_step_agent"] = {
    ["description"] = "Retry the current blocked agent step after agent spawn or lifecycle failure. Clears stale session linkage on the current run step visit and requeues the pipeline-owned agent spawn. If run_id is omitted, the caller's active pipeline assignment is used.",
    ["input_schema"] = {
      ["properties"] = {
        ["reason"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["run_step_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["search_tickets"] = {
    ["description"] = "Search tickets by text, status, project, target, and whether closed tickets should be included.",
    ["input_schema"] = {
      ["properties"] = {
        ["include_closed"] = {
          ["type"] = "boolean",
        },
        ["limit"] = {
          ["type"] = "integer",
        },
        ["project_id"] = {
          ["type"] = "string",
        },
        ["query"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "open",
            "active",
            "blocked",
            "closed",
          },
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
      },
      ["type"] = "object",
    },
  },
  ["spawn_ticket_session"] = {
    ["description"] = "Spawn an agent or accessory in a ticket's worktree context. Reuses a live ticket worktree when available, otherwise opens the ticket branch.",
    ["input_schema"] = {
      ["properties"] = {
        ["accessory_name"] = {
          ["type"] = "string",
        },
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
        ["workspace_id"] = {
          ["type"] = "string",
        },
        ["workspace_name"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["start_run"] = {
    ["description"] = "Start a pipeline run for a ticket. The ticket's target_id supplies the spawn target; its filesystem path is resolved automatically for agent and command steps.",
    ["input_schema"] = {
      ["properties"] = {
        ["base_ref"] = {
          ["type"] = "string",
        },
        ["base_run_id"] = {
          ["type"] = "string",
        },
        ["base_target_path"] = {
          ["type"] = "string",
        },
        ["base_ticket_id"] = {
          ["type"] = "string",
        },
        ["parent_run_id"] = {
          ["type"] = "string",
        },
        ["pipeline_id"] = {
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
        ["workspace_id"] = {
          ["type"] = "string",
        },
        ["workspace_name"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
  ["submit_gate"] = {
    ["description"] = "Submit evidence for a pipeline gate. Agents should submit required gate evidence before requesting advancement.",
    ["input_schema"] = {
      ["properties"] = {
        ["evidence"] = {
          ["type"] = "object",
        },
        ["gate_id"] = {
          ["type"] = "string",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["run_step_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "passed",
            "failed",
            "waived",
          },
          ["type"] = "string",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
        ["summary"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "run_id",
        "step_id",
        "gate_id",
      },
      ["type"] = "object",
    },
  },
  ["submit_review"] = {
    ["description"] = "Submit a structured review for a pipeline step, including findings that become visible to every agent in the run context. This records the review; it does not advance the run. The response includes next-tool guidance when the current step still needs explicit advancement.",
    ["input_schema"] = {
      ["properties"] = {
        ["findings"] = {
          ["items"] = {
            ["properties"] = {
              ["details"] = {
                ["type"] = "string",
              },
              ["file"] = {
                ["type"] = "string",
              },
              ["line"] = {
                ["type"] = "integer",
              },
              ["severity"] = {
                ["enum"] = {
                  "blocker",
                  "high",
                  "medium",
                  "low",
                  "info",
                },
                ["type"] = "string",
              },
              ["suggested_fix"] = {
                ["type"] = "string",
              },
              ["title"] = {
                ["type"] = "string",
              },
            },
            ["required"] = {
              "title",
            },
            ["type"] = "object",
          },
          ["type"] = "array",
        },
        ["run_id"] = {
          ["type"] = "string",
        },
        ["run_step_id"] = {
          ["type"] = "string",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
        ["summary"] = {
          ["type"] = "string",
        },
        ["verdict"] = {
          ["enum"] = {
            "approved",
            "changes_required",
            "blocked",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "run_id",
        "step_id",
        "verdict",
      },
      ["type"] = "object",
    },
  },
  ["update_checklist"] = {
    ["description"] = "Update checklist metadata.",
    ["input_schema"] = {
      ["properties"] = {
        ["checklist_id"] = {
          ["type"] = "string",
        },
        ["description"] = {
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["source"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "checklist_id",
      },
      ["type"] = "object",
    },
  },
  ["update_checklist_item"] = {
    ["description"] = "Update one checklist item status and evidence. Use evidence to list vault notes read, convention conflicts, verification commands, or capture paths.",
    ["input_schema"] = {
      ["properties"] = {
        ["evidence"] = {
          ["type"] = "object",
        },
        ["item_id"] = {
          ["type"] = "string",
        },
        ["position"] = {
          ["type"] = "integer",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["source_ref"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "pending",
            "in_progress",
            "blocked",
            "skipped",
            "done",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "item_id",
      },
      ["type"] = "object",
    },
  },
  ["update_gate"] = {
    ["description"] = "Update a pipeline gate definition.",
    ["input_schema"] = {
      ["properties"] = {
        ["command"] = {
          ["type"] = "string",
        },
        ["gate_id"] = {
          ["type"] = "string",
        },
        ["kind"] = {
          ["enum"] = {
            "attestation",
            "review_clear",
            "command",
          },
          ["type"] = "string",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["required_fields"] = {
          ["items"] = {
            ["type"] = "string",
          },
          ["type"] = "array",
        },
      },
      ["required"] = {
        "gate_id",
      },
      ["type"] = "object",
    },
  },
  ["update_pipeline"] = {
    ["description"] = "Update a pipeline definition's metadata, archive state, replacement links, name, description, or merge policy.",
    ["input_schema"] = {
      ["properties"] = {
        ["archived"] = {
          ["type"] = "boolean",
        },
        ["description"] = {
          ["type"] = "string",
        },
        ["merge_policy"] = {
          ["enum"] = {
            "direct",
            "pr",
          },
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["pipeline_id"] = {
          ["type"] = "string",
        },
        ["replacement_pipeline_id"] = {
          ["type"] = "string",
        },
        ["supersedes_pipeline_id"] = {
          ["type"] = "string",
        },
        ["version_label"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "pipeline_id",
      },
      ["type"] = "object",
    },
  },
  ["update_project"] = {
    ["description"] = "Update a project's name, description, or status.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["project_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "open",
            "active",
            "blocked",
            "closed",
          },
          ["type"] = "string",
        },
      },
      ["required"] = {
        "project_id",
      },
      ["type"] = "object",
    },
  },
  ["update_step"] = {
    ["description"] = "Update a pipeline step definition.",
    ["input_schema"] = {
      ["properties"] = {
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["command"] = {
          ["type"] = "string",
        },
        ["kind"] = {
          ["enum"] = {
            "agent",
            "command",
          },
          ["type"] = "string",
        },
        ["name"] = {
          ["type"] = "string",
        },
        ["next_step_id"] = {
          ["type"] = "string",
        },
        ["on_approved_step_id"] = {
          ["type"] = "string",
        },
        ["on_blocked_step_id"] = {
          ["type"] = "string",
        },
        ["on_changes_requested_step_id"] = {
          ["type"] = "string",
        },
        ["position"] = {
          ["type"] = "integer",
        },
        ["prompt"] = {
          ["type"] = "string",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "step_id",
      },
      ["type"] = "object",
    },
  },
  ["update_step_agent"] = {
    ["description"] = "Set the Botster agent definition used by one pipeline step.",
    ["input_schema"] = {
      ["properties"] = {
        ["agent_name"] = {
          ["type"] = "string",
        },
        ["step_id"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "step_id",
        "agent_name",
      },
      ["type"] = "object",
    },
  },
  ["update_ticket"] = {
    ["description"] = "Update a ticket's title, description, project, target, or status.",
    ["input_schema"] = {
      ["properties"] = {
        ["description"] = {
          ["type"] = "string",
        },
        ["project_id"] = {
          ["type"] = "string",
        },
        ["status"] = {
          ["enum"] = {
            "open",
            "active",
            "blocked",
            "closed",
          },
          ["type"] = "string",
        },
        ["target_id"] = {
          ["type"] = "string",
        },
        ["ticket_id"] = {
          ["type"] = "string",
        },
        ["title"] = {
          ["type"] = "string",
        },
      },
      ["required"] = {
        "ticket_id",
      },
      ["type"] = "object",
    },
  },
}

local PROP = {
  string = { type = "string" },
  object = { type = "object" },
  boolean = { type = "boolean" },
  integer = { type = "integer" },
}

local function extend_contract(name, properties, required)
  local contract = TOOL_CONTRACTS[name]
  if not contract then error("missing Project Pipelines tool contract: " .. name) end
  for key, property in pairs(properties or {}) do contract.input_schema.properties[key] = property end
  if required then contract.input_schema.required = required end
  contract.input_schema.additionalProperties = true
end

-- The legacy descriptors are the public reference vocabulary. These extensions
-- describe package-owned fields needed by the cold-cut store and its importer.
extend_contract("create_project", {
  id = PROP.string, repository = PROP.object, repository_id = PROP.string,
  repository_name = PROP.string, repository_remote = PROP.string,
  spawn_target_id = PROP.string, workspace_id = PROP.string,
  status = { type = "string", enum = { "open", "active", "blocked", "closed" } },
})
extend_contract("create_ticket", {
  id = PROP.string, workspace_id = PROP.string,
  status = { type = "string", enum = { "open", "active", "blocked", "closed" } },
  dependency_ticket_ids = { type = "array", items = PROP.string },
}, { "project_id", "title" })
TOOL_CONTRACTS.create_ticket.description = "Create a project ticket. dependency_ticket_ids is an optional array of ticket IDs that is validated and atomically registered as normalized blocking dependency rows; it is never persisted on the ticket payload."
extend_contract("create_pipeline", { project_id = PROP.string })
extend_contract("create_step", { session_type_id = PROP.string })
extend_contract("update_step", { session_type_id = PROP.string })
extend_contract("start_run", {
  id = PROP.string, spawn_target_id = PROP.string, branch = PROP.string,
  worktree = PROP.object, worktree_id = PROP.string,
}, { "ticket_id", "pipeline_id" })
extend_contract("spawn_ticket_session", {
  run_id = PROP.string, step_id = PROP.string, request_id = PROP.string,
  session_type_id = PROP.string, branch = PROP.string,
  spawn_target_id = PROP.string, environment = PROP.object, metadata = PROP.object,
}, { "run_id" })
TOOL_CONTRACTS.spawn_ticket_session.input_schema.properties.accessory_name = nil
TOOL_CONTRACTS.spawn_ticket_session.input_schema.properties.agent_name = nil
TOOL_CONTRACTS.spawn_ticket_session.input_schema.properties.ticket_id = nil
TOOL_CONTRACTS.spawn_ticket_session.input_schema.properties.workspace_name = nil
TOOL_CONTRACTS.spawn_ticket_session.description = "Spawn the current pipeline step's configured agent session for a durable run, using a correlated request so retries cannot dispatch twice."
extend_contract("request_merge", { run_id = PROP.string }, { "run_id" })
TOOL_CONTRACTS.request_merge.input_schema.properties = { run_id = PROP.string }
TOOL_CONTRACTS.request_merge.description = "Atomically mark a run merge-requested while keeping its owning ticket active for provider merge reconciliation."
extend_contract("remove_ticket_dependency", {
  ticket_id = PROP.string, depends_on_ticket_id = PROP.string,
  dependency_ticket_id = PROP.string,
})
TOOL_CONTRACTS.remove_ticket_dependency.input_schema.required = nil
TOOL_CONTRACTS.remove_ticket_dependency.input_schema.anyOf = {
  { required = { "dependency_id" } },
  { required = { "ticket_id", "depends_on_ticket_id" } },
  { required = { "ticket_id", "dependency_ticket_id" } },
}
extend_contract("add_checklist_item", { text = PROP.string })
extend_contract("request_step_advance", { request_id = PROP.string }, { "run_id" })
extend_contract("remove_project_target", {
  project_id = PROP.string, target_id = PROP.string,
})
TOOL_CONTRACTS.remove_project_target.input_schema.required = nil
TOOL_CONTRACTS.remove_project_target.input_schema.anyOf = {
  { required = { "project_target_id" } },
  { required = { "project_id", "target_id" } },
}
extend_contract("create_child_run", {
  id = PROP.string, ticket_id = PROP.string,
}, { "parent_run_id", "title" })
extend_contract("create_checklist", {
  id = PROP.string, run_id = PROP.string, step_id = PROP.string,
}, { "name" })
TOOL_CONTRACTS.create_checklist.input_schema.anyOf = {
  { required = { "owner_id" } },
  { required = { "run_id" } },
}
extend_contract("list_checklists", { run_id = PROP.string })
extend_contract("list_pr_links", { ticket_id = PROP.string, run_id = PROP.string })
extend_contract("retry_step_agent", { request_id = PROP.string }, { "run_id" })
TOOL_CONTRACTS.retry_step_agent.input_schema.properties.reason = nil
TOOL_CONTRACTS.retry_step_agent.description = "Retry the current blocked agent step for the specified run after agent spawn or lifecycle failure. Clears stale session linkage on the current run step visit and reuses the durable correlated spawn request."

extend_contract("list_projects", { status = PROP.string })
extend_contract("list_tickets", { project_id = PROP.string, status = PROP.string })
extend_contract("checklist_instructions", { scope = { type = "string", enum = { "project", "ticket", "run" } } })
extend_contract("question_orchestrator_status", { project_id = PROP.string })

TOOL_CONTRACTS.resolve_repository_playbook = {
  description = "Resolve one repository or Project Pipelines package path to exactly one supported ownership charter; ambiguous and unknown inputs require a routing question.",
  input_schema = object_schema({
    repository = PROP.string, repository_name = PROP.string,
    name = PROP.string, path = PROP.string,
  }),
}
TOOL_CONTRACTS.entities = {
  description = "Inspect committed Project Pipelines records as request-facing entity frames; Hub reconnect hydration uses the package's explicit entity providers.",
  input_schema = object_schema({ run_id = PROP.string }),
}


local function authoritative_tools()
  local tools = {}
  local function add(name, call)
    local contract = TOOL_CONTRACTS[name]
    if not contract then error("missing Project Pipelines tool contract: " .. name) end
    table.insert(tools, {
      name = "project_pipelines." .. name,
      description = contract.description,
      input_schema = contract.input_schema,
      handler = name,
      call = call,
    })
  end

  add("add_artifact", record_artifact)
  add("add_checklist_item", function(arguments)
    arguments = arguments or {}
    arguments.text = arguments.text or arguments.prompt
    return add_checklist_item(arguments)
  end)
  add("add_project_target", add_project_target)
  add("add_ticket_dependency", function(arguments)
    arguments = arguments or {}
    arguments.dependency_ticket_id = arguments.dependency_ticket_id or arguments.depends_on_ticket_id
    return add_ticket_dependency(arguments)
  end)
  add("answer_question", answer_question)
  add("ask_agent", ask_agent)
  add("ask_human", ask_human)
  add("cancel_run", cancel_run)
  add("checklist_instructions", checklist_instructions)
  add("claim_question_orchestrator", claim_question_orchestrator)
  add("close_ticket", close_ticket)
  add("create_checklist", create_checklist)
  add("create_child_run", create_child_run)
  add("create_gate", create_gate)
  add("create_pipeline", create_pipeline)
  add("create_project", create_project)
  add("create_step", create_step)
  add("create_ticket", create_ticket)
  add("create_vault_checklist", create_vault_checklist)
  add("current_context", current_context)
  add("delete_gate", delete_gate)
  add("delete_pipeline", delete_pipeline)
  add("delete_project", delete_project)
  add("delete_step", delete_step)
  add("delete_ticket", delete_ticket)
  add("escalate_question", escalate_question)
  add("get_checklist", get_checklist)
  add("get_pipeline", get_pipeline)
  add("get_pr_link", get_pr_link)
  add("get_project", get_project)
  add("get_ticket", get_ticket)
  add("link_pr", link_pr)
  add("list_agent_choices", list_agent_choices)
  add("list_checklists", list_checklists)
  add("list_pipelines", list_pipelines)
  add("list_pr_links", list_pr_links)
  add("list_projects", list_projects)
  add("list_ticket_dependencies", list_ticket_dependencies)
  add("list_tickets", list_tickets)
  add("question_orchestrator_status", question_orchestrator_status)
  add("receive_question_answers", receive_question_answers)
  add("release_question_orchestrator", release_question_orchestrator)
  add("remove_project_target", remove_project_target)
  add("remove_ticket_dependency", function(arguments)
    arguments = arguments or {}
    arguments.dependency_ticket_id = arguments.dependency_ticket_id or arguments.depends_on_ticket_id
    return remove_ticket_dependency(arguments)
  end)
  add("request_merge", request_merge)
  add("request_step_advance", request_step_advance)
  add("resolve_finding", resolve_finding)
  add("retry_step_agent", retry_step_agent)
  add("search_tickets", search_tickets)
  add("spawn_ticket_session", spawn_ticket_session)
  add("start_run", start_run)
  add("submit_gate", submit_gate)
  add("submit_review", submit_review)
  add("update_checklist", update_checklist)
  add("update_checklist_item", update_checklist_item)
  add("update_gate", update_gate)
  add("update_pipeline", update_pipeline)
  add("update_project", update_project)
  add("update_step", update_step)
  add("update_step_agent", update_step_agent)
  add("update_ticket", update_ticket)

  -- Package-owned additions retained outside the 61-name legacy public contract.
  add("resolve_repository_playbook", resolve_repository_playbook)
  add("entities", entities)
  return tools
end

reconcile_sourced_pipeline()

local function authoritative_handlers()
  local handlers = {
    { id = "home_surface", kind = "surface_route", descriptor_id = "project-pipelines.home", descriptor = { title = "Project Pipelines", surface_id = "project-pipelines.home" }, call = render_home },
    { id = "settings_surface", kind = "surface_route", descriptor_id = "project-pipelines.settings", descriptor = { title = "Project Pipelines Settings", surface_id = "project-pipelines.settings" }, call = render_settings },
    { id = "create_ticket_action", kind = "ui_action", descriptor_id = "project_pipelines.create_ticket", descriptor = { action_id = "project_pipelines.create_ticket", surface_id = "project-pipelines.home" }, call = create_ticket_action },
    { id = "start_run_action", kind = "ui_action", descriptor_id = "project_pipelines.start_run", descriptor = { action_id = "project_pipelines.start_run", surface_id = "project-pipelines.home" }, call = start_run_action },
    { id = "spawn_ticket_session_action", kind = "ui_action", descriptor_id = "project_pipelines.spawn_ticket_session", descriptor = { action_id = "project_pipelines.spawn_ticket_session", surface_id = "project-pipelines.home" }, call = spawn_ticket_session_action },
    { id = "filter_action", kind = "ui_action", descriptor_id = "project_pipelines.filter", descriptor = { action_id = "project_pipelines.filter", surface_id = "project-pipelines.home" }, call = filter_action },
    { id = "select_row_action", kind = "ui_action", descriptor_id = "project_pipelines.select_row", descriptor = { action_id = "project_pipelines.select_row", surface_id = "project-pipelines.home" }, call = select_row_action },
    { id = "pr_merged", kind = "event", event = "pr_merged", descriptor_id = "pr_merged", descriptor = { event = "pr_merged" }, call = handle_pr_merged },
  }
  for _, provider in ipairs(ENTITY_PROVIDER_FAMILIES) do
    local entity_type = "project-pipelines." .. provider.family
    table.insert(handlers, {
      id = "project_pipelines_" .. provider.family .. "_entities",
      kind = "entity_provider",
      descriptor_id = entity_type,
      descriptor = { entity_type = entity_type, id_field = "id" },
      call = entity_provider_handler(provider.family, provider.records),
    })
  end
  return handlers
end

return botster.register({
  tools = authoritative_tools(),
  handlers = authoritative_handlers(),
})
