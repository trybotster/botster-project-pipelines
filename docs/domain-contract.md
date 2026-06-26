# Project Pipelines Domain Contract

This repository defines the Project Pipelines plugin domain contract. It does
not implement the workflow engine yet. The runtime package remains the
installable scaffold declared by `botster-package.json` and the inert
`plugin.lua` entrypoint.

`botster-package.json` is the source of truth for package descriptors:

- package name: `project-pipelines`
- capability: `surfaces`
- Lua entrypoint: `plugin.lua`
- configuration schema placeholder: `{ "groups": [], "fields": [] }`
- app surface: `project-pipelines.home`
- settings surface: `project-pipelines.settings`

## Runtime Disposition

The current production path is scaffold-only package discovery and enablement. The
changed user path for this ticket is reviewable repo-local documentation,
fixtures, and `script/test` validation of the domain contract. No provider,
workspace, MCP, UI workbench, or pipeline engine code is added in this pass.

## Domain Objects

Project Pipelines owns durable workflow state for a project and its tickets.
Provider-owned facts and workspace-provided grouping are linked by stable IDs
instead of copied into plugin source files.

| Object | Ownership | Contract |
| --- | --- | --- |
| Project | Plugin-owned | Product or repository grouping for tickets. Stores standalone repo and spawn-target config, and may store optional workspace IDs. |
| Ticket | Plugin-owned | Unit of delivery within a project. Stores title, description, status, dependency links, and optional workspace ID. |
| Pipeline definition | Plugin-owned | Ordered step template selected for a ticket run. Defines steps, gate prompts, and default routing. |
| Step | Plugin-owned | Named execution phase such as Plan, Review, Implement, Verify, or Merge. |
| Gate | Plugin-owned | Required evidence prompt or command attached to a step. Gate results are persisted on runs. |
| Run | Plugin-owned | One execution of a pipeline definition for a ticket, with current step, status, assignments, and event history. |
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
- Artifacts, findings, questions, answers, gate results, and PR links are linked
  to runs and, when useful for review, to the exact run step that created them.
- Questions have many answers. Answers reference their question and answering
  actor.
- PR links reference provider-owned identifiers but are not provider clients.

## Persistence Boundaries

Plugin-owned durable records belong in Project Pipelines runtime storage, such
as `plugin-data/project-pipelines/db.sqlite` when the runtime engine is added.
Mutable runtime records must not be written under the plugin source tree.

Provider-owned facts remain external facts. Project Pipelines may cache stable
references and lifecycle observations, but provider APIs, OAuth, webhooks, and
pull-request mutations belong to provider implementations outside this scaffold.

Workspace integration is optional. Standalone Project Pipelines records must be
complete with explicit repository and spawn-target configuration. When a
workspace plugin is present, Project Pipelines may store workspace IDs and use
workspace-provided repo/session grouping as linked context.

## Provider Capability Contract

A provider implementation can support Project Pipelines by exposing abstract
capabilities. This repository only defines the required facts and lifecycle
boundaries:

- repository identity and display name
- explicit spawn target ID for agent sessions
- branch, worktree, base ref, and run context
- session or agent lifecycle events with stable session IDs
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
