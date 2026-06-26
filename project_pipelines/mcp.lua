local engine = require("project_pipelines.engine")
local entities = require("project_pipelines.entities")

local M = {}

local function empty_schema()
  return {
    type = "object",
    properties = {},
    additionalProperties = false,
  }
end

local function object_schema(properties, required)
  return {
    type = "object",
    properties = properties,
    required = required or {},
    additionalProperties = true,
  }
end

function M.tools()
  return {
    {
      name = "project_pipelines.create_project",
      description = "Create a Project Pipelines project with standalone repository and spawn target references.",
      input_schema = object_schema({
        id = { type = "string" },
        name = { type = "string" },
        repository = { type = "object" },
        repository_id = { type = "string" },
        repository_name = { type = "string" },
        repository_remote = { type = "string" },
        spawn_target_id = { type = "string" },
        workspace_id = { type = "string" },
      }, { "name", "spawn_target_id" }),
      handler = "create_project",
      call = engine.create_project,
    },
    {
      name = "project_pipelines.list_projects",
      description = "List persisted Project Pipelines projects.",
      input_schema = empty_schema(),
      handler = "list_projects",
      call = engine.list_projects,
    },
    {
      name = "project_pipelines.show_project",
      description = "Show one persisted Project Pipelines project.",
      input_schema = object_schema({ project_id = { type = "string" } }, { "project_id" }),
      handler = "show_project",
      call = engine.show_project,
    },
    {
      name = "project_pipelines.create_ticket",
      description = "Create a Project Pipelines ticket linked to a project.",
      input_schema = object_schema({
        id = { type = "string" },
        project_id = { type = "string" },
        workspace_id = { type = "string" },
        title = { type = "string" },
        description = { type = "string" },
        status = { type = "string" },
        dependency_ticket_ids = { type = "array" },
      }, { "project_id", "title" }),
      handler = "create_ticket",
      call = engine.create_ticket,
    },
    {
      name = "project_pipelines.list_tickets",
      description = "List persisted Project Pipelines tickets.",
      input_schema = object_schema({ project_id = { type = "string" } }),
      handler = "list_tickets",
      call = engine.list_tickets,
    },
    {
      name = "project_pipelines.show_ticket",
      description = "Show one persisted Project Pipelines ticket.",
      input_schema = object_schema({ ticket_id = { type = "string" } }, { "ticket_id" }),
      handler = "show_ticket",
      call = engine.show_ticket,
    },
    {
      name = "project_pipelines.define_pipeline",
      description = "Define a simple ordered Project Pipelines template.",
      input_schema = object_schema({
        id = { type = "string" },
        project_id = { type = "string" },
        name = { type = "string" },
        steps = { type = "array" },
      }, { "project_id", "name" }),
      handler = "define_pipeline",
      call = engine.define_pipeline,
    },
    {
      name = "project_pipelines.list_pipeline_definitions",
      description = "List persisted Project Pipelines templates.",
      input_schema = empty_schema(),
      handler = "list_pipeline_definitions",
      call = engine.list_pipeline_definitions,
    },
    {
      name = "project_pipelines.show_pipeline_definition",
      description = "Show one Project Pipelines template.",
      input_schema = object_schema({ pipeline_definition_id = { type = "string" } }, { "pipeline_definition_id" }),
      handler = "show_pipeline_definition",
      call = engine.show_pipeline_definition,
    },
    {
      name = "project_pipelines.record_run",
      description = "Record a Project Pipelines run skeleton without executing agents.",
      input_schema = object_schema({
        id = { type = "string" },
        ticket_id = { type = "string" },
        pipeline_definition_id = { type = "string" },
        current_step_id = { type = "string" },
        status = { type = "string" },
        workspace_session_group_id = { type = "string" },
        branch = { type = "string" },
        base_ref = { type = "string" },
        worktree = { type = "object" },
        worktree_id = { type = "string" },
      }, { "ticket_id", "pipeline_definition_id" }),
      handler = "record_run",
      call = engine.record_run,
    },
    {
      name = "project_pipelines.record_artifact",
      description = "Record a Project Pipelines artifact attached to a run.",
      input_schema = object_schema({
        id = { type = "string" },
        run_id = { type = "string" },
        step_id = { type = "string" },
        kind = { type = "string" },
        summary = { type = "string" },
        uri = { type = "string" },
      }, { "run_id" }),
      handler = "record_artifact",
      call = engine.record_artifact,
    },
    {
      name = "project_pipelines.record_question",
      description = "Record a Project Pipelines question attached to a run.",
      input_schema = object_schema({
        id = { type = "string" },
        run_id = { type = "string" },
        ticket_id = { type = "string" },
        step_id = { type = "string" },
        status = { type = "string" },
        question = { type = "string" },
      }, { "run_id", "question" }),
      handler = "record_question",
      call = engine.record_question,
    },
    {
      name = "project_pipelines.current_context",
      description = "Return persisted Project Pipelines context.",
      input_schema = empty_schema(),
      handler = "current_context",
      call = engine.current_context,
    },
    {
      name = "project_pipelines.entities",
      description = "Return client-consumable Project Pipelines entity frames.",
      input_schema = empty_schema(),
      handler = "entities",
      call = entities.snapshot,
    },
  }
end

return M
