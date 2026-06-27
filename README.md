# botster-project-pipelines

First-party Botster Project Pipelines plugin.

This package is intended to own project pipeline state, tickets, runs, gates,
questions, artifacts, findings, and provider-mediated PR lifecycle behavior as a
self-contained Botster plugin.

This repository is a production-shaped Project Pipelines plugin. It declares the
package identity, compatibility, Lua entrypoint, configuration schema
placeholder, MCP/plugin database capabilities, and app/settings surface
descriptors needed for local package install and discovery. Workflow state stays
in the plugin; PTY execution is requested from hub-owned session templates.

## Domain Contract

The current Project Pipelines domain contract lives in
[`docs/domain-contract.md`](docs/domain-contract.md). It defines projects,
tickets, pipeline definitions, steps, gates, artifacts, findings,
questions/answers, runs, PR links, provider lifecycle boundaries, events, and
persistence ownership.

The executable contract fixture is
[`fixtures/project_pipelines/domain_contract.json`](fixtures/project_pipelines/domain_contract.json).
`script/test` validates the fixture relationships, standalone mode, optional
workspace-linked mode, session-template request shape, provider capability
boundaries, manifest anchors, and PII/raw-path absence. It also loads the
production `plugin.lua` entrypoint with Botster capability stubs, creates
persisted records, activates PTY and non-PTY steps, reloads the entrypoint, and
proves the app and settings surfaces expose persisted project/ticket/run/session
state.

Runtime behavior is intentionally narrow in this pass: `plugin.lua` registers
workflow CRUD tools, a `project_pipelines.activate_step` tool, and app/settings
surface handlers. PTY-backed steps with `session_template_id` call the hub
`spawn_session_template` primitive with `DaemonSessionTemplateRequest` field
names. Manual, human, command, and other non-PTY steps do not spawn sessions.
The manifest configuration schema is intentionally empty, and provider or
workspace integrations are contract references rather than runtime imports.

## UI Contract

Project Pipelines surfaces are Botster shared `ui_contract` trees consumed by
browser and TUI renderers. Web rendering should stay React/Catalyst-side; this
plugin emits structured nodes, stable node IDs, and plugin-owned entity families
such as `project-pipelines.project`, `project-pipelines.ticket`, and
`project-pipelines.run`.

Dynamic model state belongs in plugin-owned entity output. Surface snapshots
should stay structural and declare bindings for project, ticket, run, and
session request lists instead of becoming a raw HTML or provider-specific data
transport. UI vocabulary should refer to sessions, templates, and accessories,
not a separate execution or agent runtime class.

## Local Development

Run the package checks:

```sh
script/test
```

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
