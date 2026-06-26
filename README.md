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
