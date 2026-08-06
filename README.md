# botster-project-pipelines

First-party Botster Project Pipelines plugin.

This standalone package is the only runtime and source authority for Project
Pipelines and the sourced Botster Stack Delivery workflow. It owns the durable
record schema, engine policy, MCP tools, routing allowlist, workflow definitions,
questions, gates, reviews/findings, artifacts/checklists, PR links, entity
projections, and operator surfaces. It does not read catalog code or rows, a
legacy CLI, sibling checkouts, or compatibility sources.

This repository is the production Project Pipelines plugin. It declares the
package identity, compatibility, Lua entrypoint, package configuration schema,
MCP/plugin database capabilities, navigation, and app/settings surface
descriptors needed for local package install and discovery. Workflow state stays
in the plugin; PTY execution is requested from hub-owned session templates.
The manifest declares stable surface ids and a `pipelines` navigation entry;
hub-admitted route descriptors own concrete route ids and paths.

## Domain Contract

The current Project Pipelines domain contract lives in
[`docs/domain-contract.md`](docs/domain-contract.md). It defines projects,
tickets, pipeline definitions, steps, gates, artifacts, findings,
questions/answers, runs, PR links, provider lifecycle boundaries, events, and
persistence ownership.

The executable contract fixture is
[`fixtures/project_pipelines/domain_contract.json`](fixtures/project_pipelines/domain_contract.json).
`script/test` validates fixture and manifest anchors, the closed MCP descriptor
contract, repository routing (including negative and ambiguous cases),
PII/operator-path absence, atomic lifecycle failure, dependency and gate
blocking and explicit overrides, run-step-visit-scoped review routing, correlated spawn replay, malformed
record rejection, v2 namespace removal, entity snapshots, and source reload.
It rejects descriptor properties that have no handler-side reference.
It also proves the app workbench and settings surfaces expose committed state.
The settings surface renders
`project-pipelines-provider-dependency-status`, a stable provider/dependency
status section derived from persisted session request diagnostics.

## Public MCP Contract

The production surface is closed: 61 `project_pipelines_*` tools cover project,
target, ticket/dependency, pipeline/step/gate, run/session, review/finding,
artifact/checklist, question/orchestrator, PR, context, and lifecycle behavior.
`script/test` asserts that exact set. Ten superseded package names are absent:
`activate_step`, `define_pipeline`, `list_pipeline_definitions`,
`show_pipeline_definition`, `record_run`, `record_artifact`, `record_question`,
`update_ticket_status`, `show_project`, and `show_ticket`. Two package-owned
additions remain explicit outside the 61-name legacy contract:
`resolve_repository_playbook` enforces the repository routing allowlist, and
`entities` is a request-facing inspection tool returning committed entity
frames. Reconnect hydration is served only by the explicitly declared
`project-pipelines.*` entity providers. There are no aliases or fallback
registrations.

## Drain-first Cold Cut

The real device cut is a post-merge operator action after every legacy run is
terminal. `script/cutover export LEGACY_DB ARCHIVE_JSON IMPORT_JSON` rejects
every run outside the terminal `closed`, `done`, and `cancelled` allowlist,
exports only owning projects/targets plus open or blocked tickets,
omits already-satisfied edges to closed tickets from the live import while
keeping them in the immutable archive, rejects dangling carried edges, and
aborts above the 896-key cutover budget. `script/cutover import HUB_SOCKET
IMPORT_JSON` imports through the public package MCP and reconciles authoritative
collections after an ambiguous create response before retrying.

Run `script/cutover plan` for the one-authority sequence. Snapshot first;
disable/remove the legacy device plugin before enabling package execution;
install/show/enable through the running daemon owner; import and verify package
provenance, sourced definitions, CRUD, Running Pipelines/entities, and a fresh
E2E run. Rollback is non-destructive only before the first post-verification
write: disable/remove the package before restoring the single legacy snapshot.
After package writes, forward repair is the default; destructive rollback
requires export plus explicit loss confirmation.

The harness also proves that an open ticket dependency prevents run creation,
closing the prerequisite permits an explicit retry, and atomic failure still
leaves the ticket open with no run or run-step. A separate correlated-spawn case
proves `retry_step_agent` reuses the durable result without a second dispatch.
Missing referenced tickets fail safe and planning steps remain available only
when they explicitly set `allows_open_ticket_dependencies=true`.

`plugin.lua` is the single production entrypoint consumed by the current Hub
worker sandbox. It contains the versioned prefix-addressable record repository,
the checked-in Botster Stack Delivery source/reconciliation policy, exact
repository-charter routing, gate/review/question/checklist/PR/advance handlers,
workflow CRUD, entity projections, and app/settings surface handlers.
PTY-backed steps with `session_template_id`,
`session_template_name`/`template_name`, or
`session_template_capability`/`session_capability` build and persist
the semantic inputs accepted by
`session_templates.ensure_worktree_and_spawn`: `target_id`, `branch`,
`template_id`, environment, and untrusted prompt/ticket/workspace metadata.
Hub-owned session, worktree, base-ref, and repository facts are never supplied
by the caller. Existing ID selection is direct; name and capability selection use
`session_templates.resolve` or `session_templates.list`. If a selector cannot be
resolved, or a declared dependency such as `github_auth` is unavailable,
activation persists `status="blocked"` with a structured diagnostic and emits
`session_template_spawn_blocked`. Manual, human, command, and other non-PTY
steps do not spawn sessions. The manifest configuration schema is limited to
package defaults. The `session_actions/session_template_managed_git_spawn`
capability is the narrow host grant used for correlated managed sessions;
targets, worktrees, sessions, persistence, MCP registration, workers, and
UiNode validation remain Hub-owned.

On an empty plugin database, package initialization reconciles exactly one
`botster_stack_delivery` definition and one of each sourced step/gate. Reload,
disable/enable, and Hub restart reuse those stable IDs. Checked-in source owns
metadata, prompts, transitions, gates, routing text, and `source_revision`; an
existing step's operator-selected `agent_name` remains device policy. Runtime
records live under `v3/<family>/<id>` plugin-db keys; the retired all-domain
state blob is neither read nor written. Record payloads are validated on load
and before writes. Each state transition uses one capability-gated
`plugin_db.batch` with the revisions observed during load. Starting a run
atomically activates its ticket and creates the run/current run-step; advance,
cancel, merge request, and close atomically reconcile ticket/run/run-step state
before entity or surface projection. This requires Hub commit
`11d73d27e01732981e803041ea702aa09db57112`, which contains both the atomic
plugin database ABI and generic package-owned `entity_provider` admission. The
package never simulates atomicity with sequential writes. Each package entity
family has an explicit provider returning a fresh authoritative whole-family
snapshot from committed state for initial subscription and reconnect hydration.
Diagnostic events retain the newest 256 records, and mutations fail with
`store_capacity_exhausted` before any write when the Hub's 1,024-key namespace
reaches the package's 64-key safety reserve.

Every delivery role uses the same exact routing source:

- `botster-core` → `[[botster-core-playbook]]`
- `botster-hub` → `[[botster-hub-playbook]]`
- `botster-hub-client` → `[[botster-hub-client-playbook]]`
- `botster-web` → `[[botster-web-playbook]]`
- `botster-tui` → `[[botster-tui-playbook]]`
- `botster-tui-kit` → `[[botster-tui-kit-playbook]]`
- `botster-workspaces` → `[[botster-workspaces-playbook]]`
- `botster-terminal-ghostty` → `[[botster-terminal-ghostty-playbook]]`
- Project Pipelines package/plugin paths → `[[project-pipelines-playbook]]`

Zero or multiple matches return `routing_question_required`; there is no
generic fallback or load-all behavior.

Ticket dependencies are durable normalized `ticket_dependencies` records and
are never mirrored onto ticket payloads. `create_ticket` translates its public
`dependency_ticket_ids` convenience input into those rows atomically.
`project_pipelines.add_ticket_dependency`,
`project_pipelines.remove_ticket_dependency`, and
`project_pipelines.update_ticket` mutate that lifecycle. Every step is dependency-gated unless it explicitly sets
`allows_open_ticket_dependencies=true`; standard Plan/Plan Review definitions
should set that exemption, while legacy unclassified delivery steps fail safe.
An open or missing prerequisite returns `ok=false` with
`error.code="ticket_dependencies_unmet"`. An authorized advancement persists
the source visit, requested target, correlation/result, and unmet ticket IDs in
`run.waiting_transition`; direct activation diagnostics remain in
`run.blocked_transition`. Neither path creates a target run-step, session
request, provider/template resolution, worktree, PTY, or spawn. Closing,
updating, removing, or deleting the final blocker atomically creates one target
run-step and clears the waiting state; duplicate clearance and recovery are
idempotent. Clearance is fail-closed on both ends: a cancelled, merged, or
closed run and a closed owning ticket clear their waiting state and are never
resurrected, and wakeup re-derives the route and re-checks the current gate,
review, and finding inputs, so a later `changes_required` verdict, blocking
finding, or failed gate keeps the run waiting instead of activating the agent
step. A gate override waives only the gate IDs it named and is audited when the
transition is applied, not when a dependency-blocked request was made.

Transition findings are run-scoped: unresolved `blocker` and `high` findings
stop advancement until resolved or waived. `medium`, `low`, and `info` findings
remain visible carry-forward work and do not contradict an approved review or
deadlock later steps.

## UI Contract

Project Pipelines surfaces are Botster shared `ui_contract` trees consumed by
browser and TUI renderers. Web rendering should stay React/Catalyst-side; this
plugin emits structured nodes, stable node IDs, and plugin-owned entity families
such as `project-pipelines.project`, `project-pipelines.ticket`, and
`project-pipelines.run`. The package test contract is pinned to the published
`@trybotster/ui-contract@0.1.0` registry artifact; sibling checkout, `file:`,
`link:`, path, git, and environment dependency overrides are not supported.

Stable package surface IDs are:

- app: `project-pipelines.home`
- settings/provider status: `project-pipelines.settings`

The package manifest intentionally does not declare deterministic URL route path
fields. It declares surface ids and navigation intent; runtime route paths
remain a hub-admitted route descriptor concern outside this package manifest.

Dynamic model state belongs in plugin-owned entity output. Surface snapshots
should stay structural and declare bindings for project, ticket, run, and
session request lists instead of becoming a raw HTML or provider-specific data
transport. UI vocabulary should refer to sessions, templates, and accessories,
not a separate execution or agent runtime class.

The first app render is an operator workbench, not a placeholder. It emits the
literal application UiNode primitives consumed by hub clients: `metric_grid` and
`metric` for the command-center summary, `toolbar` command/filter/action slots
for the operator controls, `section` groupings for attention/running/review
queues, `status_badge` state cues, selectable `table` rows for the
project/ticket/run/session-request drilldown, `empty_state` fallbacks, and a
`form`/`form_section`/`form_field` action feedback block for step activation.
The first viewport answers needs attention, running, and ready for review before
the drilldown tables. Entity-backed lists remain bound to
`/project-pipelines.project`, `/project-pipelines.ticket`,
`/project-pipelines.run`, and `/project-pipelines.session_request` so durable
model state stays in plugin-owned entity frames instead of the UI snapshot.
Ticket-dependency blocks appear in needs-attention and in run rows, where the
operator sees the attempted step and blocking prerequisite ticket.

Workbench controls are structured UiNodes only. Tables declare single-row
selection and row-action metadata; toolbar and form buttons route to
plugin-owned action ids such as `project_pipelines.create_ticket`,
`project_pipelines.start_run`, and `project_pipelines.spawn_ticket_session`. Raw HTML
and iframes are intentionally out of scope for CRUD/workbench controls. Future
graph or report surfaces may use an iframe only when they need a custom
full-screen visual app with an explicit plugin asset bridge.

Every plugin action consumes the complete worker-visible `UiActionRequest`
envelope: `request_id`, `surface_id`, `action_id`, optional `node_id`, `kind`,
optional form `values`, and optional non-form `payload`. The five current
operations require `kind="submit"`. Reset, validate, and cancel requests are
rejected without workflow mutation or presentation/replacement effects. Form
handlers read domain input only from `values`; filter and row selection read
metadata only from `payload`. Flat legacy arguments are not accepted.

Every Form declares an explicit `submit_label`. Create-ticket, start-run, and
spawn-step dialogs use `presentation="auto"` and are wrapped in scoped
`presentation_if` presence predicates; selected workspace content uses an
equality predicate. Dialogs never use `props.open`. Modal visibility remains
client-local presentation state, while tickets and runs remain plugin-owned
entity state. Toolbar buttons dispatch product-authored `open_dialog` payloads
that set their scoped presence keys; form submission is the only path that
invokes the matching workflow mutation.

Action results echo request, surface, action, and optional node identity exactly.
Accepted filter/select results set scoped presentation values. Accepted
mutations clear their dialog key and return the smallest direct replacement that
exposes the mutation. Rejected form results have stable input-node
`field_errors`, `form_errors`, and `normalized_values` equal to the submitted
values, with no presentation or replacement effects, so the active dialog and
operator input are retained. `tree_update` and compatibility result aliases are
not part of this contract. Workspace-linked project rows author their own
payload-bearing selection actions; table-level row actions are not used because
they cannot carry row identity.

The settings surface reports provider/dependency status without importing a
provider client. After a missing provider dependency blocks activation, the
real settings handler returns `project-pipelines-provider-dependency-status`
with blocked status and a summary naming the persisted provider/dependency
diagnostic, such as `github:github_auth`.

## Local Development

Run the package checks:

```sh
npm ci
script/test
```

`script/test` runs the registry contract assertions and the repository Lua
harness. It covers all five canonical action envelopes, submit-kind handling,
form-values/non-form-payload separation, exact optional node identity, dialog
predicates, accepted effects, rejected retention, and negative legacy calls.

Smoke the package against a real Botster Hub data directory:

```sh
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/botster-project-pipelines.XXXXXX")"
botster-hub packages install --data-dir "$DATA_DIR" --path .
botster-hub packages enable --data-dir "$DATA_DIR" project-pipelines
botster-hub packages show --data-dir "$DATA_DIR" project-pipelines
botster-hub apps list --data-dir "$DATA_DIR"
```

The `show` output should include `package name=project-pipelines`, an enabled
state, `schema_present=true`, the `surfaces`, `mcp`, and `plugin_db`
capabilities, and the declared `app` and `settings` surface descriptors.
The manifest should include the `pipelines` navigation entry and no route path
fields; route paths are supplied by the hub route descriptor layer.

Render acceptance should exercise the production package route, not only this
repository's Lua harness. The expected hub path is a packaged
`PluginSurfaceRender` request for package `project-pipelines` and surface
`project-pipelines.home`, returning `response=plugin_surface` with a surface
tree containing `toolbar`, `metric_grid`, `metric`, `section`, `status_badge`,
`table`, `empty_state`, and `form` primitives. The node shapes mirror the
canonical `botster-hub-test-support` plugin-contract-matrix fixture.

Real hub acceptance for this ticket is a live Project Pipelines activation, not
only package discovery. Use a temporary hub data directory, install and enable
this package, define a tiny standalone project/ticket/run with a PTY step
selected by template name or declared capability, activate it, then inspect
`project_pipelines.current_context`. Persisted evidence should show
`session_request.status="spawn_requested"`, `run.session_id`,
`run.session_request_id`, a `session_template_spawn_requested` event, resolved
`template_id`, persisted `template_selector`, `target_id`, and request context
metadata for `run_id`, `step_id`, and `ticket_id`. The negative case is a PTY
step declaring a missing provider dependency such as `github_auth`; activation
should persist `status="blocked"`, a diagnostic naming the dependency/provider,
and a `session_template_spawn_blocked` event without spawning a PTY session.
Ticket dependency acceptance should separately add an open prerequisite through
`project_pipelines.add_ticket_dependency`, attempt an unexempted delivery step,
and observe `ticket_dependencies_unmet` with unchanged current-step and session
state. After closing or removing the prerequisite, a later explicit activation
should spawn once and a repeat activation should reuse that request.

For the Hub-owned UI contract flow, build the exact merged Hub and its locked
Core session worker from a fresh checkout. The second binary is a
`botster-core` target pinned by that Hub commit's `Cargo.lock`; it does not carry
the Hub SHA. `script/test-hub-flow` runs both locked build commands itself after
verifying the checkout revision, so stale target artifacts cannot satisfy the
proof.

```sh
git clone https://github.com/trybotster/botster-hub.git /private/tmp/botster-hub-ui-contract
git -C /private/tmp/botster-hub-ui-contract checkout 11d73d27e01732981e803041ea702aa09db57112
cargo build --locked --manifest-path /private/tmp/botster-hub-ui-contract/Cargo.toml
cargo build --locked --manifest-path /private/tmp/botster-hub-ui-contract/Cargo.toml -p botster-core --bin botster-session-worker
BOTSTER_HUB_SOURCE=/private/tmp/botster-hub-ui-contract \
BOTSTER_HUB_BIN=/private/tmp/botster-hub-ui-contract/target/debug/botster-hub \
BOTSTER_SESSION_WORKER_BIN=/private/tmp/botster-hub-ui-contract/target/debug/botster-session-worker \
script/test-hub-flow
```

The harness verifies the Hub checkout SHA and clean worktree, reads the distinct
Core SHA from its lockfile, rebuilds both executables, confirms they came from
that checkout's target directory, installs/enables this packaged plugin in an
isolated data directory, renders the real `project-pipelines.home` entry point,
reads action IDs from returned nodes, reads workspace identity from a rendered
row action, opens the rendered dialogs, and dispatches canonical filter, select,
accepted create, and rejected create requests through the real worker. It asserts
structured `plugin_action_result` frames, exact identity, a client-authored
submit envelope, values/payload separation, close/replacement behavior, retained
normalized values/errors, and the selected-workspace equality binding. It also
admits a deterministic Git target using the real Workspaces target id, installs a
test Plan template, activates the production sourced Plan through
`ensure_worktree_and_spawn`, and waits for that spawned Plan process to inspect
its managed prompt, resolve `[[botster-workspaces-playbook]]`, and submit the Plan
artifact, gate, and step advance through the public plugin MCP socket without a
routing question. Through the running daemon's public tool-list request it also
proves the exact 63 published names, authored descriptions, nonempty serialized
schema objects/arrays, and the nested review verdict/finding enums. The harness
then restarts Hub and rechecks the same durable workflow identity.

`EXPECTED_HUB_COMMIT` in `script/test-hub-flow` records the Hub revision against
which this plugin contract was proven. Advance that pin deliberately only when
the package is re-proven against a newer Hub commit, and update the checkout
command above in the same change.
