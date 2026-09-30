-- Real-runtime behaviour of the MCP tools: the plugin loads into the Hub's
-- real Lua runtime and every call goes through the Hub's production path.
-- Run: botster-plugin-test --plugin . test/flow_spec.lua
local kit = require("botster.test")

local function tool(p, name, args, opts)
  local response = p:call_tool("project_pipelines." .. name, args, opts)
  return response.result
end

local function setup(t)
  local p = t:load(".")
  t:ok(tool(p, "create_project", { id = "project-one", name = "Project One", target_id = "target-one" }).ok)
  t:ok(tool(p, "create_pipeline", {
    id = "pipeline-one", name = "One step", steps = { { id = "step-one", name = "One" } },
  }).ok)
  t:ok(tool(p, "create_ticket", { id = "ticket-one", project_id = "project-one", title = "Ticket" }).ok)
  local run = tool(p, "start_run", { id = "run-one", ticket_id = "ticket-one", pipeline_id = "pipeline-one" })
  t:ok(run.ok, "start_run")
  return p
end

kit.test("the Hub lists every tool descriptor the manifest contract names", function(t)
  local p = t:load(".")
  local names = {}
  for _, descriptor in ipairs(p:tools()) do names[#names + 1] = descriptor.name end
  table.sort(names)
  t:eq(#names, 63)
  t:eq(names[1], "project_pipelines.add_artifact")
end)

kit.test("a question is emitted through the Hub's event router and stored", function(t)
  local p = setup(t)
  local asked = tool(p, "ask_human", { run_id = "run-one", ticket_id = "ticket-one", question = "Continue?" })
  t:ok(asked.ok, "ask_human")
  local events = p:emitted_events()
  t:eq(#events, 1)
  t:match(events[1], { owner = "project-pipelines", name = "question.opened" })
  t:eq(events[1].payload.question_id, asked.question.id)
  local answered = tool(p, "answer_question", { question_id = asked.question.id, answer = "Yes" })
  t:ok(answered.ok, "answer_question")
  t:eq(#tool(p, "receive_question_answers", { all = true }).answers, 1)
end)

kit.test("a merged pull request closes its run and is emitted through the router", function(t)
  local p = setup(t)
  t:ok(tool(p, "link_pr", { run_id = "run-one", url = "https://example.invalid/pull/1" }).ok)
  local merged = tool(p, "link_pr", {
    run_id = "run-one", url = "https://example.invalid/pull/1", status = "merged", merge_commit = "deadbeef",
  })
  t:ok(merged.ok, "merged link")
  t:eq(merged.run.status, "closed")
  local events = p:emitted_events()
  t:eq(#events, 1)
  t:match(events[1], { name = "pr_merged" })
  t:eq(events[1].payload.merge_commit, "deadbeef")
end)

kit.test("the caller is the session the Hub verified, not an argument", function(t)
  local p = setup(t)
  local as_orchestrator = { caller = { session_id = "orchestrator-session" } }
  local claim = tool(p, "claim_question_orchestrator", { project_id = "project-one", session_uuid = "forged" }, as_orchestrator)
  t:ok(claim.ok, "claim")
  t:eq(claim.orchestrator.session_uuid, "orchestrator-session")
  t:eq(tool(p, "question_orchestrator_status", {}).orchestrators[1].session_uuid, "orchestrator-session")

  local asked = tool(p, "ask_human", { run_id = "run-one", ticket_id = "ticket-one", question = "Continue?" },
    { caller = { session_id = "requester-one" } })
  t:ok(asked.ok, "ask_human")
  t:eq(asked.question.asked_by, "requester-one")
  t:ok(tool(p, "answer_question", { question_id = asked.question.id, answer = "Yes" }).ok)
  t:eq(#tool(p, "receive_question_answers", {}, { caller = { session_id = "requester-one" } }).answers, 1)
  t:eq(#tool(p, "receive_question_answers", {}, { caller = { session_id = "someone-else" } }).answers, 0)

  t:eq(tool(p, "release_question_orchestrator", { project_id = "project-one" }, { caller = { session_id = "someone-else" } }).released, false)
  t:ok(tool(p, "release_question_orchestrator", { project_id = "project-one" }, as_orchestrator).ok)
  t:eq(#tool(p, "question_orchestrator_status", {}).orchestrators, 0)
end)
