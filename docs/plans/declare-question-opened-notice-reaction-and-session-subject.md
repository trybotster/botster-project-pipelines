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

## Revision history

- Revision 1 (`f90f856`) returned by Plan Review `review_1787299729_447587` with verdict
  `changes_required`.
- Revision 2 (`fabdc13`) answered `finding_1787299729_681476` (race-free live subject proof),
  `finding_1787299729_445118` (recorded Botster context), and `finding_1787299729_131016`
  (owned convention supersession). Plan Review `review_1787300188_975210` accepted the first
  two and returned one product finding.
- Revision 3 (this document) answers `finding_1787300188_619787`: the supersession now requires
  the durable note and charter edits with vault validation, not only an inbox capture.

## Other role and surface playbooks and atomic notes loaded

- [[planner-playbook]]
- [[botster-planner-playbook]]
- [[botster-architecture]]
- [[project pipeline orchestration belongs in a device-level botster plugin]]
- [[project pipelines needs an operator workbench not more primitives]]
- [[project pipelines ui contract belongs in the plugin readme]]
- [[botster orchestration should spawn agents with explicit target ids]]
- [[botster orchestration prompts must bind agents to explicit worktrees]]
- [[client notice reactions belong to package declarations not client constants]]
- [[generic botster clients must not hardcode package event reactions]]
- [[event plane client proof uses library contract fixtures]]
- [[question opened clients subscribe with empty subjects]]
- [[Package-event subject filters are exact strings compiled at admission]]
- [[web package event notices are transient and entity state is durable]]
- [[project pipelines mcp create calls can time out after committing]]

How the Botster overlay notes constrain this work:

- [[botster-architecture]] places the change at the package boundary. Hub owns admission and
  projection; the package owns its emitted contract; clients own rendering.
- [[project pipeline orchestration belongs in a device-level botster plugin]] keeps the workflow
  policy, including the subject source, inside this plugin instead of core or client code.
- [[project pipelines needs an operator workbench not more primitives]] rules out a new
  configuration primitive for TTL or severity. One fixed declaration is enough.
- [[project pipelines ui contract belongs in the plugin readme]] places the notice contract text
  in this repository's `README.md`, next to the manifest it governs.
- [[botster orchestration should spawn agents with explicit target ids]] and
  [[botster orchestration prompts must bind agents to explicit worktrees]] govern the live lane:
  its spawn uses the explicit admitted target id already used by `script/hub_acceptance_smoke`,
  and the held fixture session stays in its own managed worktree.

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
   - Add a race-free subject-targeting lane. See "Live subject proof" below.
   - Keep the existing plugin-audience sidecar proof unchanged.
5. `README.md` and `docs/domain-contract.md`
   - Document the notice reaction, the `subject` payload field, the subject source, and the
     new Hub checkout commit in the pin instructions.
   - Record the superseded client rule: a client no longer needs `subjects: []` plus local
     workflow filtering to receive a session-scoped `question.opened` notice.
6. Vault convention supersession (owned, not deferred)
   - Verify supersedes [[question opened clients subscribe with empty subjects]] and edits both
     conflicting [[project-pipelines-playbook]] entries, then runs vault validation.
     See "Convention supersession ownership" below.

## Live subject proof (replaces the revision 1 design)

Revision 1 planned to subscribe with the Plan session uuid of `run_live_authority`. That is
wrong. `script/hub_acceptance_smoke` drives `run_live_authority` past Plan before
`script/test-hub-flow` reaches its `question.opened` section at line 421. At that ask point the
run's current run step is a later step with no session binding, so the planned subject would be
absent and the subscription would prove nothing.

The corrected lane creates its own deterministic window. `project_pipelines.spawn_ticket_session`
returns the session id synchronously and binds the current run step before the tool returns;
`script/hub_acceptance_smoke` already asserts that join. The only race is the fixture agent
advancing the run, so the lane uses a session type that never advances.

1. Install a second fixture session type, `notice-subject.fixture/hold`. Its entry script writes
   a ready file and then waits for a release file. It calls no pipeline tool.
2. Create run `run_notice_subject` on the live ticket with `project_pipelines.start_run`.
   It starts at Plan.
3. Call `project_pipelines.spawn_ticket_session` for `botster_stack_plan` with an explicit
   `session_type_id` of `notice-subject.fixture/hold` and the same explicit admitted
   `spawn_target_id` the smoke lane uses. Wait for the ready file with a bounded timeout.
4. At the exact ask point, call `project_pipelines.current_context` for that run. Require
   `run.current_run_step_id` to name the Plan visit and that visit's `agent_session_uuid` to be
   a nonempty string. Bind it as `expected_subject`. Fail the lane when either condition is
   false, rather than proceeding with a stale or empty identity.
5. Open subscription A (`subjects: [expected_subject]`) and subscription B
   (`subjects: ["not-this-session"]`) for owner `project-pipelines`, name `question.opened`.
   Wait for both `event_subscribed` acknowledgements. Package events are live-only, so both
   subscriptions must exist before the ask.
6. Call `project_pipelines.ask_human` on `run_notice_subject`.
7. A receives exactly one `package_event` frame within a 5 second bound. Assert
   `payload.subject == expected_subject` and that the notice text resolves through `/notice`.
8. Bounded negative, ordered after A already delivered: `IO.select` on B for 3 seconds must
   return nil. Ordering the check after A's frame makes B's silence meaningful instead of a
   timing artifact.
9. No-binding case: create run `run_notice_unbound` and never spawn its session, so its current
   Plan visit carries no `agent_session_uuid`. Ask one question on it. The plugin-audience
   sidecar must receive that event, proving emission still happened, and its payload must have
   no `subject` key. Ordered after that sidecar observation, subscription A must stay silent for
   3 seconds.
10. Release the held fixture session in an `ensure` block so the managed process exits.

## Convention supersession ownership

The ticket requires this work to update or supersede
[[question opened clients subscribe with empty subjects]]. Revision 1 left it as a post-merge
capture candidate with no owning stage, so no gate could fail if it never happened.

Revision 2 required only a vault inbox capture. That is not enough. An inbox file is raw input
under the vault workflow. It leaves the note at `status: current` and leaves two conflicting
rules live in the Project Pipelines charter. Revision 3 requires the durable edits themselves.

- Implement owns the in-repository half: `README.md` and `docs/domain-contract.md` record the
  session-subject targeting rule and mark the subjectless rule historical.
- Verify owns the vault half, in this run. The vault is a separate target
  (`tgt_74d58fdf4c2341619ea8d879b3833193`), but the ticket states the supersession is part of
  this work, so it is not registered as a dependency prerequisite.

Verify performs all of the following before requesting merge:

1. Write the inbox capture first, following the vault workflow.
2. Promote it to a durable replacement note that states the new rule: a client targets a
   `question.opened` notice with the session subject supplied by the package declaration, and
   needs no Project Pipelines entity or field knowledge. The note names the human decision
   `question_1787278509_823001` and links to
   [[client notice reactions belong to package declarations not client constants]].
3. Edit `notes/question opened clients subscribe with empty subjects.md`: set
   `status: superseded` and add a `superseded_by` wiki link to the replacement note. Keep its
   body as historical context, including why the subjectless rule was true before the payload
   schema declared `subject`.
4. Edit `notes/project-pipelines-playbook.md` at both conflicting entries:
   - line 67, the Must Load entry that tells consumers to use no subject filter;
   - line 103, the Required Gates entry that requires `subjects: []` and rejects nonempty
     subject filters.
   Both must state the new rule and mark the old one superseded.
5. Run `ops/scripts/validate-schema.sh` and `ops/scripts/dangling-links.sh`, and keep their
   output as evidence. The `superseded_by` link and both charter edits must resolve.
6. Set vault checklist item 4 to `done`.

Completion condition: Verify gate evidence carries the changed note paths, the two validation
command outputs, and a `done` vault checklist item 4. A pending item 4, an unchanged note
status, or a surviving `subjects: []` charter rule blocks the merge request.

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
- `script/test-hub-flow` -- `EXPECTED_HUB_COMMIT`, the packages-frame descriptor assertion, the
  held `notice-subject.fixture/hold` session type, and the client `subscribe_events` subject
  proof with its bounded negative cases.
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
7. **Held fixture session leak.** The live lane keeps one managed session waiting on a release
   file. An early failure could leave that process running. Mitigation: write the release file
   from an `ensure` block, so every exit path releases the held session.
8. **Bounded negatives are timing claims.** A negative subscription assertion proves only that
   nothing arrived inside its window. Mitigation: order each negative check after a positive
   delivery on another subscription, so the router has demonstrably already dispatched.

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
   - at the ask point, the run's current run step carries a nonempty `agent_session_uuid`, and
     the lane fails closed when it does not;
   - the subscription whose `subjects` list holds that exact current-run-step session uuid
     receives one `question.opened` frame within 5 seconds, with `payload.subject` equal to it;
   - a mismatched-subject subscription stays silent for a bounded 3 seconds, checked after the
     matching subscription already delivered;
   - a run with no current session binding still emits the event to the plugin-audience sidecar
     with no `subject` key, while the session-filtered subscription stays silent for a bounded
     3 seconds;
   - the plugin-audience sidecar still receives the original smoke-lane event.
4. Production-path proof: the changed code path is `record_question`, which every
   `project_pipelines.ask_human` and `project_pipelines.ask_agent` call reaches. The live lane
   exercises that public tool through the real Hub daemon socket, not a Lua stub.
5. Evidence discipline: record the commit and clean tracked state before and after each gate
   command, per [[verification evidence is scoped to a stable commit and clean tree]].
6. Convention supersession, checked before the merge request: the superseded note carries
   `status: superseded` with a resolving `superseded_by` link; neither
   [[project-pipelines-playbook]] entry still requires `subjects: []`;
   `ops/scripts/validate-schema.sh` and `ops/scripts/dangling-links.sh` pass; vault checklist
   item 4 is `done`.

## Vault gaps worth capturing

1. Supersede [[question opened clients subscribe with empty subjects]] and correct both
   conflicting [[project-pipelines-playbook]] entries. Its rule (empty subject set plus
   client-side workflow filtering) is replaced by session-subject targeting for the notice path.
   This one is owned, not deferred: see "Convention supersession ownership". Verify performs the
   durable note and charter edits, with validation output, before requesting merge.
2. Capture that Hub supplies no caller session identity to plugin MCP tool calls, so a package
   must derive agent session identity from its own durable records. This finding is not in the
   vault today and it decided the design.
3. Capture the admitted `events.notices` authoring shape and its seven admission rules as a
   package-facing note, so the next package author does not re-read Hub source.
4. Note the registry lag: the Hub source publishes `@trybotster/ui-contract@0.3.3` and
   `@trybotster/hub-test-support@0.1.40`, while the npm registry serves older versions. Consumer
   repositories cannot pin the new contract until publication happens.
