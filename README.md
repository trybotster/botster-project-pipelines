# botster-project-pipelines

First-party Botster Project Pipelines plugin.

This package is intended to own project pipeline state, tickets, runs, gates,
questions, artifacts, findings, and provider-mediated PR lifecycle behavior as a
self-contained Botster plugin.

This repository is currently a production-shaped package scaffold. It declares
the package identity, compatibility, inert Lua entrypoint, configuration schema
placeholder, and app/settings surface descriptors needed for local package
install and discovery. It does not port the Project Pipelines workflow engine
yet.

## Domain Contract

The current Project Pipelines domain contract lives in
[`docs/domain-contract.md`](docs/domain-contract.md). It defines projects,
tickets, pipeline definitions, steps, gates, artifacts, findings,
questions/answers, runs, PR links, provider lifecycle boundaries, events, and
persistence ownership.

The executable contract fixture is
[`fixtures/project_pipelines/domain_contract.json`](fixtures/project_pipelines/domain_contract.json).
`script/test` validates the fixture relationships, standalone mode, optional
workspace-linked mode, provider capability boundaries, manifest anchors, and
PII/raw-path absence.

Runtime behavior remains scaffold-only in this pass: `plugin.lua` is inert, the
manifest configuration schema is intentionally empty, and provider or workspace
integrations are contract references rather than runtime imports.

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
state, `schema_present=true`, and the declared `app` and `settings` surface
descriptors. The app list may be empty until runnable entrypoints are added in a
future implementation pass.
