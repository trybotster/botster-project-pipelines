local database = {}
local registrations = {}
local publish_calls = {}
local batch_calls = {}
local conflict_provider_cas_once = false
local spawn_count = 0

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = copy(nested)
  end
  return result
end

local function apply_set(request)
  local current = database[request.key]
  local current_revision = current and (current.revision or 1) or 0
  if request.expected_revision ~= nil and request.expected_revision ~= current_revision then
    return {
      ok = false,
      error_kind = "revision_conflict",
      message = "revision conflict for " .. request.key,
      key = request.key,
    }
  end
  local revision = current_revision + 1
  database[request.key] = {
    schema_version = request.schema_version or 4,
    payload = copy(request.payload),
    revision = revision,
  }
  return { ok = true, record = copy(database[request.key]) }
end

botster = {
  entity_publish = function(frame)
    publish_calls[#publish_calls + 1] = copy(frame)
    return {
      ok = true,
      status = "accepted",
      last_accepted_seq = frame.snapshot_seq,
      high_water_seq = frame.snapshot_seq,
    }
  end,
  capabilities = {
    plugin_db = {
      get = function(request)
        local record = database[request.key]
        return record and { record = copy(record) } or { kind = "record" }
      end,
      list = function(request)
        local prefix = request.prefix or ""
        local entries = {}
        for key, record in pairs(database) do
          if key:sub(1, #prefix) == prefix then
            entries[#entries + 1] = { key = key, revision = record.revision or 1 }
          end
        end
        table.sort(entries, function(left, right) return left.key < right.key end)
        return { entries = entries }
      end,
      batch = function(request)
        batch_calls[#batch_calls + 1] = copy(request)
        local mutations = request.mutations or {}
        if conflict_provider_cas_once
          and #mutations == 1
          and type(mutations[1].key) == "string"
          and mutations[1].key:find("entity_seq", 1, true)
        then
          conflict_provider_cas_once = false
          return {
            ok = false,
            error_kind = "revision_conflict",
            message = "injected provider sequence conflict",
            mutation_index = 1,
            key = mutations[1].key,
          }
        end
        local snapshot = copy(database)
        local results = {}
        for index, mutation in ipairs(mutations) do
          if mutation.operation == "set" then
            local result = apply_set(mutation)
            if not result.ok then
              database = snapshot
              result.mutation_index = index
              return result
            end
            results[#results + 1] = result
          elseif mutation.operation == "delete" then
            local current = database[mutation.key]
            local current_revision = current and (current.revision or 1) or 0
            if mutation.expected_revision ~= current_revision then
              database = snapshot
              return {
                ok = false,
                error_kind = "revision_conflict",
                message = "delete revision conflict",
                mutation_index = index,
                key = mutation.key,
              }
            end
            if not current then
              database = snapshot
              return {
                ok = false,
                error_kind = "store_not_found",
                message = "missing key",
                mutation_index = index,
                key = mutation.key,
              }
            end
            database[mutation.key] = nil
            results[#results + 1] = { ok = true, key = mutation.key, revision = current_revision }
          else
            database = snapshot
            return {
              ok = false,
              error_kind = "invalid_request",
              message = "unsupported mutation",
              mutation_index = index,
              key = mutation.key,
            }
          end
        end
        return { ok = true, results = results }
      end,
    },
    config = {
      get = function()
        return { values = {} }
      end,
    },
    session_types = {
      ensure_worktree_and_spawn = function(request)
        spawn_count = spawn_count + 1
        return {
          session_id = "session-" .. tostring(spawn_count),
          worktree_id = "worktree-" .. tostring(spawn_count),
          target_id = request.target_id,
        }
      end,
    },
  },
  register = function(spec)
    registrations[#registrations + 1] = spec
    return spec
  end,
}

events = {
  emit = function()
    return { status = "accepted" }
  end,
  on = function()
    error("production plugin.lua must not subscribe")
  end,
}

local function assert_true(value, message)
  if not value then error(message or "assertion failed") end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function tool(spec, name)
  for _, candidate in ipairs(spec.tools or {}) do
    if candidate.name == name then return candidate.call end
  end
  error("missing tool " .. name)
end

local function handler(spec, id)
  for _, candidate in ipairs(spec.handlers or {}) do
    if candidate.id == id then return candidate end
  end
  error("missing handler " .. id)
end

local function upvalue(fn, name)
  local index = 1
  while true do
    local key, value = debug.getupvalue(fn, index)
    if not key then return nil end
    if key == name then return value end
    index = index + 1
  end
end

local function last_publish()
  return publish_calls[#publish_calls]
end

local function publishes_for(entity_type)
  local frames = {}
  for _, frame in ipairs(publish_calls) do
    if frame.entity_type == entity_type then frames[#frames + 1] = frame end
  end
  return frames
end

local function batch_has_key(batch, key)
  for _, mutation in ipairs(batch.mutations or {}) do
    if mutation.key == key then return mutation end
  end
  return nil
end

local function seq_key(family)
  return "v4/meta/entity_seq/" .. family
end

local spec = dofile("plugin.lua")
assert_eq(#registrations, 1, "plugin registers exactly once")

local create_project = tool(spec, "project_pipelines.create_project")
local create_pipeline = tool(spec, "project_pipelines.create_pipeline")
local create_ticket = tool(spec, "project_pipelines.create_ticket")
local start_run = tool(spec, "project_pipelines.start_run")
local ask_human = tool(spec, "project_pipelines.ask_human")
local answer_question = tool(spec, "project_pipelines.answer_question")
local add_artifact = tool(spec, "project_pipelines.add_artifact")
local spawn_ticket_session = tool(spec, "project_pipelines.spawn_ticket_session")
local current_context = tool(spec, "project_pipelines.current_context")

assert_eq(create_project({
  id = "project-runtime",
  name = "Runtime",
  target_id = "target-runtime",
}).ok, true, "create project")
assert_eq(create_pipeline({
  id = "pipeline-runtime",
  name = "Runtime",
  steps = {
    { id = "plan", name = "Plan", next_step_id = "implement" },
    { id = "implement", name = "Implement", kind = "pty", session_type_id = "runtime/implement" },
  },
}).ok, true, "create pipeline")
assert_eq(create_ticket({
  id = "ticket-runtime",
  project_id = "project-runtime",
  title = "Runtime ticket",
}).ok, true, "create ticket")
local started = start_run({
  id = "run-runtime",
  ticket_id = "ticket-runtime",
  pipeline_id = "pipeline-runtime",
})
assert_eq(started.ok, true, "start run")

local question_seq_before = database[seq_key("question")]
assert_true(question_seq_before == nil, "question seq starts absent")

-- 1. record_question publishes one entity_upsert with snapshot_seq = last+1
--    and reserves the counter in the same batch.
local publish_before = #publish_calls
local asked = ask_human({
  id = "question-runtime-open",
  run_id = "run-runtime",
  ticket_id = "ticket-runtime",
  question = "Publish this row?",
})
assert_eq(asked.ok, true, "ask_human succeeds")
assert_eq(#publish_calls, publish_before + 1, "ask_human publishes one frame")
local asked_frame = last_publish()
assert_eq(asked_frame.type, "entity_upsert", "ask_human publishes entity_upsert")
assert_eq(asked_frame.entity_type, "project-pipelines.question", "ask_human family")
assert_eq(asked_frame.id, "question-runtime-open", "ask_human id")
assert_eq(asked_frame.snapshot_seq, 1, "first question seq is 1")
assert_eq(asked_frame.entity.status, "open", "published question is open")
assert_eq(asked_frame.entity._store_position, nil, "published row omits store position")
assert_eq(database[seq_key("question")].payload.next_seq, 1, "question counter reserved to 1")
local asked_batch = batch_calls[#batch_calls - (#publish_calls == publish_before + 1 and 0 or 0)]
-- The commit batch is the one that contains both the question row and the seq key.
local commit_batch
for index = #batch_calls, 1, -1 do
  local candidate = batch_calls[index]
  if batch_has_key(candidate, "v4/questions/question-runtime-open")
    and batch_has_key(candidate, seq_key("question"))
  then
    commit_batch = candidate
    break
  end
end
assert_true(commit_batch, "question mutation and seq reservation share one batch")
assert_eq(batch_has_key(commit_batch, seq_key("question")).payload.next_seq, 1, "same-batch seq is last+1")

-- 2. answer_question publishes the changed question row; unchanged families stay silent.
publish_before = #publish_calls
local artifact_before = #publish_calls
assert_eq(add_artifact({
  id = "artifact-runtime",
  run_id = "run-runtime",
  kind = "report",
  summary = "non-published family",
}).ok, true, "add artifact")
assert_eq(#publish_calls, artifact_before, "artifact mutation publishes nothing")
local answered = answer_question({
  question_id = "question-runtime-open",
  answer = "Yes",
})
assert_eq(answered.ok, true, "answer_question succeeds")
assert_eq(#publish_calls, publish_before + 1, "answer_question publishes one frame")
local answered_frame = last_publish()
assert_eq(answered_frame.type, "entity_upsert", "answer publishes upsert")
assert_eq(answered_frame.entity_type, "project-pipelines.question", "answer family")
assert_eq(answered_frame.entity.status, "answered", "answered status")
assert_eq(answered_frame.entity.answer_id ~= nil, true, "answer_id set")
assert_eq(answered_frame.snapshot_seq, 2, "answer advances question seq")
assert_eq(#publishes_for("project-pipelines.session_request"), 0, "answer does not publish session_request")

-- 3. Session activation publishes spawning then spawn_requested; second carries session_id.
publish_before = #publish_calls
local spawned = spawn_ticket_session({
  run_id = "run-runtime",
  step_id = "implement",
  request_id = "session-runtime-1",
})
assert_eq(spawned.ok, true, "spawn succeeds: " .. tostring(spawned.error and spawned.error.message))
local session_frames = {}
for index = publish_before + 1, #publish_calls do
  if publish_calls[index].entity_type == "project-pipelines.session_request" then
    session_frames[#session_frames + 1] = publish_calls[index]
  end
end
assert_true(#session_frames >= 2, "activation publishes at least spawning and result upserts")
assert_eq(session_frames[1].entity.status, "spawning", "first session_request is spawning")
assert_eq(session_frames[#session_frames].entity.status, "spawn_requested", "final session_request is spawn_requested")
assert_eq(session_frames[#session_frames].entity.session_id, "session-1", "final frame carries session_id")
assert_eq(database[seq_key("session_request")].payload.next_seq, #session_frames, "session_request seq matches frame count")

-- 8. Non-published family already covered by artifact above; keep a later check too.

-- 4. Forced failure: throw twice, then ok=false stale_sequence twice.
local original_publish = botster.entity_publish
local attempts = 0
botster.entity_publish = function(_frame)
  attempts = attempts + 1
  error("injected transient entity_publish failure")
end
publish_before = #publish_calls
local failed_ask = ask_human({
  id = "question-runtime-degraded-throw",
  run_id = "run-runtime",
  ticket_id = "ticket-runtime",
  question = "Degrade on throw?",
})
assert_eq(failed_ask.ok, true, "durable question commits when publish throws")
assert_eq(attempts, 2, "throwing publish is retried once")
local degraded_context = current_context({ run_id = "run-runtime" })
local throw_events = 0
for _, event in ipairs(degraded_context.events) do
  if event.kind == "entity_publish_degraded" and event.payload and event.payload.id == "question-runtime-degraded-throw" then
    throw_events = throw_events + 1
    assert_eq(event.payload.code, "entity_publish_failed", "throw diagnostic code")
    assert_true(type(event.payload.message) == "string" and event.payload.message ~= "", "throw diagnostic message")
    assert_true(#event.payload.message <= 280, "throw diagnostic message is bounded")
  end
end
assert_eq(throw_events, 1, "one degraded event for the throwing frame")
assert_true(database["v4/questions/question-runtime-degraded-throw"] ~= nil, "thrown publish keeps the question")

attempts = 0
botster.entity_publish = function(_frame)
  attempts = attempts + 1
  return { ok = false, status = "stale_sequence", last_accepted_seq = 9, high_water_seq = 9 }
end
local stale_ask = ask_human({
  id = "question-runtime-degraded-stale",
  run_id = "run-runtime",
  ticket_id = "ticket-runtime",
  question = "Degrade on stale_sequence?",
})
assert_eq(stale_ask.ok, true, "durable question commits when publish returns ok=false")
assert_eq(attempts, 2, "stale_sequence is retried once")
degraded_context = current_context({ run_id = "run-runtime" })
local stale_events = 0
for _, event in ipairs(degraded_context.events) do
  if event.kind == "entity_publish_degraded" and event.payload and event.payload.id == "question-runtime-degraded-stale" then
    stale_events = stale_events + 1
    assert_eq(event.payload.code, "stale_sequence", "stale diagnostic uses Hub status")
  end
end
assert_eq(stale_events, 1, "one degraded event for stale_sequence")

-- 5. ok=true non-accepted statuses are admitted: no retry storm, no diagnostic.
attempts = 0
local admitted_events_before = 0
degraded_context = current_context({ run_id = "run-runtime" })
for _, event in ipairs(degraded_context.events) do
  if event.kind == "entity_publish_degraded" then admitted_events_before = admitted_events_before + 1 end
end
for _, status in ipairs({ "pending_gap", "resync_scheduled" }) do
  attempts = 0
  botster.entity_publish = function(frame)
    attempts = attempts + 1
    return {
      ok = true,
      status = status,
      last_accepted_seq = (frame.snapshot_seq or 1) - 1,
      high_water_seq = frame.snapshot_seq,
    }
  end
  local admitted = ask_human({
    id = "question-runtime-" .. status,
    run_id = "run-runtime",
    ticket_id = "ticket-runtime",
    question = "Admit " .. status .. "?",
  })
  assert_eq(admitted.ok, true, status .. " keeps tool success")
  assert_eq(attempts, 1, status .. " is not retried")
end
degraded_context = current_context({ run_id = "run-runtime" })
local admitted_events_after = 0
for _, event in ipairs(degraded_context.events) do
  if event.kind == "entity_publish_degraded" then admitted_events_after = admitted_events_after + 1 end
end
assert_eq(admitted_events_after, admitted_events_before, "admitted statuses record no diagnostic")
botster.entity_publish = original_publish

-- 6. Provider CAS: snapshot allocates last+1 and retries once on seeded revision conflict.
local question_provider = handler(spec, "project_pipelines_question_entities")
assert_eq(question_provider.kind, "entity_provider", "question provider registered")
assert_eq(question_provider.descriptor.entity_type, "project-pipelines.question", "question provider family")
local seq_before_provider = database[seq_key("question")].payload.next_seq
conflict_provider_cas_once = true
local provider_batches_before = #batch_calls
local snapshot = question_provider.call({ subscription_id = "runtime-sub" })
assert_eq(snapshot.type, "entity_snapshot", "provider returns snapshot")
assert_eq(snapshot.entity_type, "project-pipelines.question", "provider family")
assert_eq(snapshot.snapshot_seq, seq_before_provider + 1, "provider allocates last+1")
assert_eq(database[seq_key("question")].payload.next_seq, seq_before_provider + 1, "provider CAS advances seq")
assert_true(#batch_calls >= provider_batches_before + 2, "provider retried the seeded revision conflict")
local found_open
for _, item in ipairs(snapshot.items) do
  if item.id == "question-runtime-open" then found_open = item end
end
assert_true(found_open and found_open.status == "answered", "provider snapshot includes durable rows")

-- Other families keep the in-memory counter.
local artifact_provider = handler(spec, "project_pipelines_artifact_entities")
local first_artifact_snapshot = artifact_provider.call({})
local second_artifact_snapshot = artifact_provider.call({})
assert_eq(second_artifact_snapshot.snapshot_seq, first_artifact_snapshot.snapshot_seq + 1, "unpublished family keeps in-memory seq")
assert_true(database[seq_key("artifact")] == nil, "unpublished family has no persisted seq key")

-- 7. Record deletion in a published family emits entity_remove.
local ask_question = upvalue(ask_human, "ask_question")
local record_question = upvalue(ask_question, "record_question")
local load_state = upvalue(record_question, "load_state")
local save_state = upvalue(record_question, "save_state")
assert_true(type(load_state) == "function" and type(save_state) == "function", "persist seam is reachable for delete coverage")
local deleted_id = "question-runtime-degraded-throw"
assert_true(database["v4/questions/" .. deleted_id] ~= nil, "delete fixture exists")
publish_before = #publish_calls
local state = load_state()
for index, question in ipairs(state.questions) do
  if question.id == deleted_id then
    table.remove(state.questions, index)
    break
  end
end
assert_eq(save_state(state), nil, "delete save succeeds")
local remove_frame
for index = publish_before + 1, #publish_calls do
  if publish_calls[index].type == "entity_remove" and publish_calls[index].id == deleted_id then
    remove_frame = publish_calls[index]
  end
end
assert_true(remove_frame, "deleted published row emits entity_remove")
assert_eq(remove_frame.entity_type, "project-pipelines.question", "remove family")
assert_eq(remove_frame.entity, nil, "remove frame has no entity body")
assert_true(type(remove_frame.snapshot_seq) == "number" and remove_frame.snapshot_seq > 0, "remove has seq")
assert_true(database["v4/questions/" .. deleted_id] == nil, "deleted question key is gone")

-- 8. Non-published family publishes nothing (artifact already asserted; checklist too).
publish_before = #publish_calls
assert_eq(add_artifact({
  id = "artifact-runtime-2",
  run_id = "run-runtime",
  kind = "report",
  summary = "still unpublished",
}).ok, true, "second artifact")
assert_eq(#publish_calls, publish_before, "second artifact still publishes nothing")

print("project-pipelines plugin runtime entity mutation checks passed")
