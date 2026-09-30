-- Live smoke: the plugin against a REAL daemon process, driven only through its
-- socket as an MCP client is. Run with the candidate Hub binaries from the Hub's
-- own gate:
--   BOTSTER_HUB_BIN=... BOTSTER_SESSION_WORKER_BIN=... BOTSTER_CANDIDATE_MANIFEST=... \
--     script/test-e2e
local kit = require("botster.test")

local function tool(p, name, args)
  local response = p:call_tool("project_pipelines." .. name, args)
  return response.result
end

kit.test("the Hub serves the tools, and a ticket runs a pipeline through a question to a merged PR", function(t)
  local p = t:load(".")

  -- The daemon lists the plugin's tools.
  local names = {}
  for _, descriptor in ipairs(p:tools()) do names[#names + 1] = descriptor.name end
  t:ok(#names >= 60, "the daemon lists the project_pipelines tools, got " .. #names)

  t:ok(tool(p, "create_project", { id = "smoke-project", name = "Smoke", target_id = "smoke-target" }).ok)
  t:ok(tool(p, "create_pipeline", {
    id = "smoke-pipeline", name = "One step", steps = { { id = "smoke-step", name = "One" } },
  }).ok)
  t:ok(tool(p, "create_ticket", { id = "smoke-ticket", project_id = "smoke-project", title = "Smoke ticket" }).ok)
  local run = tool(p, "start_run", { id = "smoke-run", ticket_id = "smoke-ticket", pipeline_id = "smoke-pipeline" })
  t:ok(run.ok, "start_run")

  -- A question survives a round trip through the real daemon.
  local asked = tool(p, "ask_human", { run_id = "smoke-run", ticket_id = "smoke-ticket", question = "Continue?" })
  t:ok(asked.ok, "ask_human")
  t:ok(tool(p, "answer_question", { question_id = asked.question.id, answer = "Yes" }).ok)
  t:eq(#tool(p, "receive_question_answers", { all = true }).answers, 1)

  -- A merged PR closes the run.
  t:ok(tool(p, "link_pr", { run_id = "smoke-run", url = "https://example.invalid/pull/1" }).ok)
  local merged = tool(p, "link_pr", {
    run_id = "smoke-run", url = "https://example.invalid/pull/1", status = "merged", merge_commit = "deadbeef",
  })
  t:ok(merged.ok, "merged link")
  t:eq(merged.run.status, "closed")
  t:eq(tool(p, "current_context", { run_id = "smoke-run" }).run.status, "closed")

  -- The plugin's own log reaches the Hub without a warning or error.
  for _, record in ipairs(p:logs()) do
    t:ok(record.level ~= "error" and record.level ~= "warn", "unexpected " .. record.level .. ": " .. tostring(record.message))
  end
end)
