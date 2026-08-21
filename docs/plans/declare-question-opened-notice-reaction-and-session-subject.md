# Plan: declare the `question.opened` notice reaction and emit the session subject

Ticket: `ticket_1787278658_151737`
Run: `run_1787298821_679193`
Base: `origin/main` at `cd7c2f926fcead78e15e7a9c713ad26dfe883914`

## Target repository and target id

- Target repository: `botster-project-pipelines` (package `project-pipelines`).
- Target id: `tgt_a72ca1a83d504385b8648f71409119ab`.
- Resolution source: run `target_id` matched against `list_spawn_targets`, not the process directory.

## Repository playbook loaded

- [[project-pipelines-playbook]] (Project Pipelines package paths are the whole scope).

## Other role and surface playbooks and atomic notes loaded

- [[planner-playbook]]
- [[botster-planner-playbook]]
- [[client notice reactions belong to package declarations not client constants]]
- [[generic botster clients must not hardcode package event reactions]]
- [[event plane client proof uses library contract fixtures]]
- [[question opened clients subscribe with empty subjects]]
- [[Package-event subject filters are exact strings compiled at admission]]
- [[web package event notices are transient and entity state is durable]]
- [[project pipelines mcp create calls can time out after committing]]

Runtime-teardown class does not apply. This ticket changes one manifest declaration, one
emitted payload field, and test lanes. It does not touch WebRTC, peer lifecycle,
`SessionIo`, `ClientWorker` teardown, multi-peer ownership, or terminal-state divergence.

## Context loaded

- Ticket text plus the human decision of record `question_1787278509_823001`.
- Dependency `ticket_1787278643_145174` (Hub), status closed. Merge commit
  `12e0cc6994be18024e4bdfffb22947526a652204` is the current `trybotster/botster-hub` `main`.
- Hub contract source read at that commit:
  - `crates/botster-ui-contract/src/notices.rs` -- declaration, descriptor, validation, and
    `resolve_notice_text`.
  - `src/packages.rs` -- `events.notices` admission rules.
  - `crates/botster-hub-client/src/lib.rs` and `generated/daemon-protocol.ts` -- optional
    `notice_reactions` on `DaemonPackage`.
  - `examples/event-plane-producer/botster-package.json` and
    `fixtures/plugins/plugin-contract-matrix/botster-package.json` -- authored shape.
- This repository: `botster-package.json`, `plugin.lua` (`record_question`, `ask_question`,
  `reconcile_run_step_session_bindings`), `script/test`, `script/test-hub-flow`,
  `script/test-ui-contract.mjs`, `test/plugin_runtime_test.lua`, `README.md`,
  `docs/domain-contract.md`.

### Admitted Hub contract (facts this plan depends on)

A declaration lives at `events.notices[]` in `botster-package.json` with fields
`owner` (optional), `name`, `subject_scope`, `text_pointer`, `ttl_ms`, `severity`.
Hub rejects a declaration unless all of the following hold:

1. `owner`, when present, equals the package name.
2. `name` names an admitted `events.emitted` entry.
3. That emitted event includes the `clients` audience.
4. That event's `payload_schema.properties` declares `subject`, and `subject` accepts a string.
5. The `text_pointer` property exists in the same properties map and accepts a string.
6. `subject_scope` is `session`; `severity` is `info`, `warning`, or `error`.
7. `ttl_ms` is inside `1000..=60000`.
8. `text_pointer` is one top-level RFC 6901 pointer.

Hub projects the declaration to clients as `DaemonPackage.notice_reactions[]` with `owner`
always set to the admitted package name. Client subject matching stays exact-string matching
on `payload.subject` ([[Package-event subject filters are exact strings compiled at admission]]).

## Scope

1. `botster-package.json`
   - Add `subject` (`{"type": "string", "maxLength": 128}`) to the `question.opened`
     `payload_schema.properties`. The schema keeps `additionalProperties: false`, so this
     addition is required before the plugin may emit a subject at all.
   - Add one `events.notices` entry: `name: "question.opened"`, `subject_scope: "session"`,
     `text_pointer: "/notice"`, `ttl_ms: 10000`, `severity: "warning"`. Omit `owner` so the
     admitted package identity is the only owner source.
2. `plugin.lua` -- `record_question`
   - After the durable commit, resolve the active agent session uuid from package state:
     the question's `run_id` selects the run, `run.current_run_step_id` selects the run step,
     and `run_step.agent_session_uuid` is the subject when it is a nonempty string.
   - Set `payload.subject` only when that value exists. Emit no `subject` key otherwise.
   - Keep emission after `save_state` and keep it inside the existing `pcall`.
3. `script/test` (static manifest and source guards, plus the inline Lua harness)
   - Assert the manifest declares exactly one notice reaction with the exact field values.
   - Assert `question.opened` `payload_schema.properties.subject` exists and accepts a string.
   - Assert through the Lua harness that a question on a run with a bound run step emits
     `payload.subject` equal to that binding, and that a question on a run without a binding
     emits no `subject` key.
   - Assert the durable question record is committed before the emit call runs.
4. `script/test-hub-flow` (live Hub lane)
   - Advance `EXPECTED_HUB_COMMIT` to `12e0cc6994be18024e4bdfffb22947526a652204`.
   - Prove Hub admits the manifest and projects the descriptor: read the packages frame and
     assert `notice_reactions` for package `project-pipelines` contains
     `owner: "project-pipelines"`, `name: "question.opened"`, `subject_scope: "session"`,
     `text_pointer: "/notice"`, `ttl_ms: 10000`, `severity: "warning"`.
   - Prove client-audience subject targeting on the existing live run whose Plan step already
     has a spawned session: open one `subscribe_events` subscription for owner
     `project-pipelines`, name `question.opened`, `subjects: [<spawned session uuid>]`, and a
     second subscription with `subjects: ["not-this-session"]`. Ask one question on that run.
     The matching subscription receives one `package_event` frame whose `payload.subject`
     equals the spawned session uuid and whose `payload.notice` resolves through `/notice`.
     The non-matching subscription receives none.
   - Keep the existing plugin-audience sidecar proof unchanged.
5. `README.md` and `docs/domain-contract.md`
   - Document the notice reaction, the `subject` payload field, the subject source, and the
     new Hub checkout commit in the pin instructions.

## Non-scope

- No entity family, field path, `run_id`, `ticket_id`, `step_id`, or workflow join is exported
  to clients as a targeting mechanism. Those payload fields already exist and stay unchanged;
  clients do not need them to target the notice.
- No change to durable question state, question entity families, or entity providers.
- No second notice reaction. `pr_merged` stays plugin-audience only and gains no declaration.
- No change to the client repositories. Botster Web and Botster TUI removal of hardcoded
  product constants belongs to `ticket_1787278327_274484` and `ticket_1787278327_199618`.
- No npm dependency bump. `package.json` keeps `@trybotster/ui-contract@0.1.0` and
  `@trybotster/hub-test-support@0.1.24`. See "Assumptions and unknowns".
- No new plugin configuration field for TTL or severity. The declaration is a fixed bounded
  presentation contract.

## Repository ownership boundaries and cross-repo dependencies

- This repository owns the package manifest declaration, the emitted payload, and the proof
  that its emitted event matches its published contract
  ([[event plane client proof uses library contract fixtures]]).
- Hub owns admission, validation, projection, and the exact-subject filter. This plan reads
  those rules and does not restate or reimplement them in Lua.
- Clients own rendering. They receive `owner`, `name`, `subject_scope`, `text_pointer`,
  `ttl_ms`, and `severity` from the projection and nothing product-specific
  ([[client notice reactions belong to package declarations not client constants]]).
- Cross-repository dependency: `ticket_1787278643_145174` (botster-hub), already closed and
  merged at `12e0cc6994be18024e4bdfffb22947526a652204`. No new dependency ticket is required
  for the planned scope.

## Assumptions and unknowns

1. **Subject source.** Hub supplies no caller session identity to plugin MCP tool calls.
   `DaemonRequest::PluginMcpCallTool` carries only `name` and `arguments`, and neither
   `botster-hub` nor `botster-core` sets a `session_uuid` context key. So
   `context.session_uuid`, and therefore `question.asked_by`, is empty on every production
   call today. The only package-owned source of the active agent session uuid is
   `run_step.agent_session_uuid` on the run's current run step. This plan uses that source and
   treats "the active agent session context exists" as "the question names a run whose current
   run step carries a session binding".
2. **Questions without a run.** `ask_human` accepts `ticket_id` alone. Such a question emits no
   subject, so a subject-filtered subscriber receives no notice. The ticket states that
   outcome explicitly, so this is intended behavior, not a gap.
3. **TTL and severity.** `ttl_ms: 10000` and `severity: "warning"` are planner defaults inside
   the admitted bounds. A question needs operator attention, so `warning` is chosen over
   `info`. Plan Review may replace either value; neither affects the code path.
4. **npm contract fixtures.** The published notice vocabulary ships in
   `@trybotster/ui-contract@0.3.3` with `@trybotster/hub-test-support@0.1.40`. The npm registry
   currently publishes at most `0.3.2` and `0.1.39`, and `README.md` forbids `file:`, `link:`,
   sibling checkout, path, git, and environment overrides. So local validation against the
   published notice vectors is not reachable in this run. The live Hub lane proves admission
   and projection against the merged Hub binary instead, which is the stronger proof. If Plan
   Review requires the npm vectors, that requires a botster-hub publication ticket first.
5. **Live lane cost.** `script/test-hub-flow` builds Hub and the locked Core session worker
   from a fresh checkout. That build is long but is the existing, required lane for this
   repository's live proof.

## Affected surfaces and files

- `botster-package.json` -- `events.emitted[question.opened].payload_schema.properties.subject`
  and the new `events.notices` array.
- `plugin.lua` -- `record_question` only (near the existing `events.emit("question.opened", ...)`
  call around line 1979).
- `script/test` -- manifest guards plus the inline Lua harness assertions.
- `script/test-hub-flow` -- `EXPECTED_HUB_COMMIT`, the packages-frame descriptor assertion, and
  the client `subscribe_events` subject proof.
- `README.md` -- notice reaction contract text and the Hub checkout commit in the pin block.
- `docs/domain-contract.md` -- `question.opened` payload description.
- `docs/plans/declare-question-opened-notice-reaction-and-session-subject.md` -- this plan.

## Risks

1. **Admission failure closes the whole package.** A malformed `events.notices` entry fails
   `validate_event_contracts`, which can block package admission entirely. Mitigation: the
   live Hub lane installs and enables the package, so a bad declaration fails the run instead
   of reaching an operator.
2. **`additionalProperties: false`.** Emitting `subject` before the schema declares it makes
   the router reject the event. Mitigation: the manifest change and the Lua change ship in one
   commit, and the Lua harness asserts both directions.
3. **Empty or wrong subject.** A missing binding must omit the key, never emit an empty string.
   An empty string is a legal exact-match value and would create a subject that no client can
   match deliberately. Mitigation: emit only for a nonempty string, asserted in `script/test`.
4. **Stale Hub pin.** Leaving `EXPECTED_HUB_COMMIT` at `d52c3eb` would run the live lane
   against a Hub that rejects `events.notices` as an unknown field. Mitigation: the pin advance
   is in scope, and the old pin is an ancestor of the new one.
5. **Convention conflict.** [[question opened clients subscribe with empty subjects]] states the
   opposite client rule. It stays true for a client that wants every question, and false as the
   only targeting story. The note must be superseded, not silently left in place.
6. **Repository text guards.** `script/test` scans every tracked file for operator paths, mail
   addresses, and retired selector vocabulary. New documentation and this plan must avoid those
   patterns.

## Acceptance checks and tests

1. `script/test` passes. It now asserts:
   - exactly one notice reaction, with the exact declared field values and no `owner` key;
   - `question.opened` declares a string `subject` property;
   - a run-bound question emits `payload.subject` equal to `run_step.agent_session_uuid`;
   - an unbound question emits no `subject` key;
   - the durable question record exists in the store before the emit call.
2. `npm test` (`script/test-ui-contract.mjs`) still passes unchanged.
3. Live Hub lane, from a fresh checkout of `trybotster/botster-hub` at
   `12e0cc6994be18024e4bdfffb22947526a652204`, with both locked builds, then
   `script/test-hub-flow`. It asserts:
   - Hub admits and enables this package with the notice declaration present;
   - the packages frame projects `notice_reactions` with `owner: "project-pipelines"` and the
     declared values;
   - the client subscription whose `subjects` list holds the spawned Plan session uuid receives
     one `question.opened` frame with `payload.subject` equal to that uuid;
   - a subscription with a different subject receives nothing;
   - the plugin-audience sidecar still receives the same event.
4. Production-path proof: the changed code path is `record_question`, which every
   `project_pipelines.ask_human` and `project_pipelines.ask_agent` call reaches. The live lane
   exercises that public tool through the real Hub daemon socket, not a Lua stub.
5. Evidence discipline: record the commit and clean tracked state before and after each gate
   command, per [[verification evidence is scoped to a stable commit and clean tree]].

## Vault gaps worth capturing

1. Supersede [[question opened clients subscribe with empty subjects]]. Its rule (empty subject
   set plus client-side workflow filtering) is replaced by session-subject targeting for the
   notice path. Capture the replacement after merge.
2. Capture that Hub supplies no caller session identity to plugin MCP tool calls, so a package
   must derive agent session identity from its own durable records. This finding is not in the
   vault today and it decided the design.
3. Capture the admitted `events.notices` authoring shape and its seven admission rules as a
   package-facing note, so the next package author does not re-read Hub source.
4. Note the registry lag: the Hub source publishes `@trybotster/ui-contract@0.3.3` and
   `@trybotster/hub-test-support@0.1.40`, while the npm registry serves older versions. Consumer
   repositories cannot pin the new contract until publication happens.
