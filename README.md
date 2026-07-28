# botster-project-pipelines

First-party Botster Project Pipelines plugin.

This package is intended to own project pipeline state, tickets, runs, gates,
questions, artifacts, findings, and provider-mediated PR lifecycle behavior as a
self-contained Botster plugin.

This repository is a production-shaped Project Pipelines plugin. It declares the
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
`script/test` validates the fixture relationships, standalone mode, optional
workspace-linked mode, session-template request shape, template selector
resolution, blocked provider diagnostics, provider capability boundaries,
manifest anchors, and PII/raw-path absence. It also loads the
production `plugin.lua` entrypoint with Botster capability stubs, creates
persisted records, activates PTY and non-PTY steps, reloads the entrypoint, and
proves the app workbench and settings surfaces expose persisted
project/ticket/run/session state. The settings surface also renders
`project-pipelines-provider-dependency-status`, a stable provider/dependency
status section derived from persisted session request diagnostics.

The harness also exercises the public ticket-dependency lifecycle through the
registered production tools: it adds a dependency after a run starts, proves an
open prerequisite blocks Implement without changing the current step or
creating a session request, closes/removes the prerequisite, explicitly retries,
and proves each run spawns only once. Missing referenced tickets fail safe and
planning steps remain available only when they explicitly set
`allows_open_ticket_dependencies=true`.

Runtime behavior is intentionally narrow in this pass: `plugin.lua` registers
workflow CRUD tools, a `project_pipelines.activate_step` tool, and app/settings
surface handlers. PTY-backed steps with `session_template_id`,
`session_template_name`/`template_name`, or
`session_template_capability`/`session_capability` build and persist
`DaemonSessionTemplateRequest` field names, add resolved `template_id` and
optional `session_id`, and call the hub `session_templates.spawn` plugin
capability. Existing ID selection is direct; name and capability selection use
`session_templates.resolve` or `session_templates.list`. If a selector cannot be
resolved, or a declared dependency such as `github_auth` is unavailable,
activation persists `status="blocked"` with a structured diagnostic and emits
`session_template_spawn_blocked`. Manual, human, command, and other non-PTY
steps do not spawn sessions. The manifest configuration schema is intentionally
limited to package defaults, and provider or workspace integrations are contract
references rather than runtime imports.

Ticket dependencies use `ticket.dependency_ticket_ids` as their sole canonical
representation. `project_pipelines.add_ticket_dependency`,
`project_pipelines.remove_ticket_dependency`, and
`project_pipelines.update_ticket_status` mutate that lifecycle without
auto-advancing a run. Every step is dependency-gated unless it explicitly sets
`allows_open_ticket_dependencies=true`; standard Plan/Plan Review definitions
should set that exemption, while legacy unclassified delivery steps fail safe.
An open or missing prerequisite returns `ok=false` with
`error.code="ticket_dependencies_unmet"`, persists the attempted step and unmet
ticket IDs in `run.blocked_transition`, and performs no step transition,
session-request creation, provider/template resolution, or spawn. Closing or
removing the blocker permits a later explicit retry, and repeated activation of
an already spawned run/step reuses the existing request.

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
`project_pipelines.record_run`, and `project_pipelines.activate_step`. Raw HTML
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

Every Form declares an explicit `submit_label`. Create-ticket, record-run, and
activate-step dialogs use `presentation="auto"` and are wrapped in scoped
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
git -C /private/tmp/botster-hub-ui-contract checkout d79403c74520fa054fb8b5996958dcf739d2fee3
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
normalized values/errors, and the selected-workspace equality binding.

`EXPECTED_HUB_COMMIT` in `script/test-hub-flow` records the Hub revision against
which this plugin contract was proven. Advance that pin deliberately only when
the package is re-proven against a newer Hub commit, and update the checkout
command above in the same change.
