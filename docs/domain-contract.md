# Project Pipelines Domain Contract

This repository defines and implements the first Project Pipelines plugin
domain path. Pipeline workflow state is plugin-owned, while PTY execution is
delegated to hub-owned session templates. The runtime package is declared by
`botster-package.json` and wired through the `plugin.lua` entrypoint.

`botster-package.json` is the source of truth for package descriptors:

- package name: `project-pipelines`
- capabilities: `surfaces`, `mcp`, and `plugin_db`
- Lua entrypoint: `plugin.lua`
- configuration schema placeholder: `{ "groups": [], "fields": [] }`
- app surface: `project-pipelines.home`
- settings surface: `project-pipelines.settings`

## Runtime Disposition

The current production path is local workflow CRUD plus PTY-backed step
activation through hub session templates. `plugin.lua` is self-contained because
the installed Lua package runtime does not expose the standard module loader. It
registers MCP-style tools for project, ticket, pipeline definition, run, step
activation, artifact, question, context, and entity-frame operations, and
registers app/settings `surface_route` handlers for `project-pipelines.home`
and `project-pipelines.settings`.

Project Pipelines does not create an agent runtime. For a PTY-backed step with a
`session_template_id`, `project_pipelines.activate_step` builds a
`DaemonSessionTemplateRequest`-shaped payload and calls the hub
`spawn_session_template` primitive. The request uses the hub-client field names:
`target_id`, optional `cwd`, optional `environment`, and `context` containing
`worktree_path`, `repo_path`, `branch_name`, `prompt`, `ticket_id`, optional
`workspace_id`, and `metadata`. Manual, human, command, and other non-PTY steps
do not call `spawn_session_template`.

No workspace-owned grouping, PR lifecycle mutation, merge workflow, provider
runtime, notification policy, or `botster-agents` class is added in this pass.

## Domain Objects

Project Pipelines owns durable workflow state for a project and its tickets.
Provider-owned facts and workspace-provided grouping are linked by stable IDs
instead of copied into plugin source files.

| Object | Ownership | Contract |
| --- | --- | --- |
| Project | Plugin-owned | Product or repository grouping for tickets. Stores standalone repo and spawn-target config, and may store optional workspace IDs. |
| Ticket | Plugin-owned | Unit of delivery within a project. Stores title, description, status, dependency links, and optional workspace ID. |
| Pipeline definition | Plugin-owned | Ordered step template selected for a ticket run. Defines steps, gate prompts, and default routing. |
| Step | Plugin-owned | Named execution phase such as Plan, Review, Implement, Verify, or Merge. PTY-backed steps may reference a hub `session_template_id`. |
| Gate | Plugin-owned | Required evidence prompt or command attached to a step. Gate results are persisted on runs. |
| Run | Plugin-owned | One execution of a pipeline definition for a ticket, with current step, status, assignments, and event history. |
| Session request | Plugin-owned summary of hub-owned lifecycle | Correlation record for a requested hub session template spawn. Stores request/session IDs, template ID, status, bounded prompt/context summary, and returned context/session references. |
| Artifact | Plugin-owned | Durable plan, report, command output, patch summary, or external URL attached to a run step. |
| Finding | Plugin-owned | Review or verification issue linked to a run step, with severity, status, and suggested fix. |
| Question | Plugin-owned | Durable human or agent question linked to a run, ticket, or step. |
| Answer | Plugin-owned | Durable response to a question. Answers do not mutate the original question text. |
| PR link | Provider fact cached by plugin | Pull request URL, provider ID, lifecycle status, and merge facts linked to a ticket or run. |
| Event | Plugin-owned | Append-only audit record of state changes, provider observations, gate submissions, and step transitions. |

## Relationships

- A project has many tickets and may have many pipeline definitions.
- A ticket belongs to one project and may have zero or more runs.
- A pipeline definition has ordered steps.
- A step may define zero or more gates.
- A run belongs to one ticket and one pipeline definition.
- A run records current step state and append-only events.
- PTY-backed steps may create session request records; the hub remains the
  authority for the template registry, target policy, context injection, and PTY
  lifecycle.
- Artifacts, findings, questions, answers, gate results, and PR links are linked
  to runs and, when useful for review, to the exact run step that created them.
- Questions have many answers. Answers reference their question and answering
  actor.
- PR links reference provider-owned identifiers but are not provider clients.

## Persistence Boundaries

Plugin-owned durable records belong in Project Pipelines runtime storage, such
as `plugin-data/project-pipelines/db.sqlite` when the runtime engine is added.
Mutable runtime records must not be written under the plugin source tree. The
minimal implementation stores one versioned plugin-owned state document through
the Botster plugin database capability.

Provider-owned facts remain external facts. Project Pipelines may cache stable
references and lifecycle observations, but provider APIs, OAuth, webhooks, and
pull-request mutations belong to provider implementations outside this scaffold.

Workspace integration is optional. Standalone Project Pipelines records must be
complete with explicit repository and spawn-target configuration. When a
workspace plugin is present, Project Pipelines may store workspace IDs and use
workspace-provided repo/session grouping as linked context. Missing or failing
workspace data must not block a standalone session-template spawn request.

## Provider Capability Contract

A provider implementation can support Project Pipelines by exposing abstract
capabilities. This repository only defines the required facts and lifecycle
boundaries:

- repository identity and display name
- explicit spawn target ID for hub sessions
- branch, worktree, base ref, and run context
- hub session-template lifecycle events with stable session IDs
- PR link creation, status observation, ready-for-review, merge, and close facts
- durable artifact, finding, question, answer, gate, and review persistence
- notification delivery for human and agent questions

Provider descriptors must be capability-level. They must not require GitHub,
Codex, or any other specific implementation in this package.

## Workspace Integration Contract

Standalone mode is mandatory. A project can run with only:

- `repository.id`
- `repository.name`
- `repository.remote`
- `spawn_target_id`

The workspace-linked mode is additive. When `botster-workspaces` is installed or an
equivalent workspace source is available, Project Pipelines may link:

- project `workspace_id`
- ticket `workspace_id`
- run `workspace_session_group_id`
- workspace-provided repository grouping
- workspace-provided session grouping

Workspace IDs are references, not ownership transfers. Missing workspace data
must not make standalone project, ticket, run, or provider records invalid.

## Event Boundaries

Events are append-only workflow audit records. They should record state changes
and external observations, not raw transcripts or secret-bearing payloads.

Expected event kinds include:

- `ticket_created`
- `run_started`
- `step_started`
- `step_activation_preserved`
- `session_template_spawn_requested`
- `gate_submitted`
- `artifact_added`
- `finding_opened`
- `question_asked`
- `answer_recorded`
- `provider_pr_linked`
- `provider_pr_ready_for_review`
- `provider_pr_merged`
- `run_completed`

## Fixtures

`fixtures/project_pipelines/domain_contract.json` is the executable contract
example. It uses synthetic IDs only and is validated by `script/test` for JSON
shape, required relationships, standalone and workspace-linked examples,
manifest anchors, provider capability boundaries, and PII/raw-path absence.
`script/test` also runs a headless Lua runtime harness against `plugin.lua` to
prove CRUD persistence survives an entrypoint reload, PTY-backed step activation
calls `spawn_session_template` with the real hub DTO field names, optional
workspace IDs stay metadata only, non-PTY steps preserve existing behavior, and
app/settings surface handlers expose persisted project, ticket, run, and session
state.
