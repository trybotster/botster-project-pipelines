---
ticket: ticket_1787200699_360898
run: run_1787200746_538984
step: botster_stack_plan
target_id: tgt_a72ca1a83d504385b8648f71409119ab
target_repository: botster-project-pipelines
plan_revision: 1
---

# Project Pipelines: publish live entity mutations for question and session_request records

## Target repository and target_id

| Field | Value |
| --- | --- |
| Target repository | `botster-project-pipelines` (`trybotster/botster-project-pipelines`) |
| target_id | `tgt_a72ca1a83d504385b8648f71409119ab` (resolved from `list_spawn_targets`, not the ambient directory) |
| Base commit | `beaba94` (branch `project-pipelines/ticket_1787200699_360898`, clean tree) |
| Pinned Hub | `d52c3ebc4190286c4b7c3812f8c65251c646ade5` (`EXPECTED_HUB_COMMIT` in `script/test-hub-flow`) |

## Repository playbook loaded

- [[project-pipelines-playbook]] — this repository is the Project Pipelines plugin itself, so its ownership charter is the Project Pipelines charter. The routing map has no separate entry for this repository; the package/plugin-path rule applies.

## Other role/surface playbooks and atomic notes loaded

- [[planner-playbook]]
- [[botster-planner-playbook]]
- [[a transient package event cannot be the sole authority for a durable close]] — durable truth stays in package persistence; events and entity frames are delivery, not authority.
- [[question opened clients subscribe with empty subjects]] — the transient `question.opened` notice contract stays unchanged next to the new entity path.
- [[botster entity snapshots are authoritative reconnect baselines]] — snapshots replace family state; published deltas must not diverge from the snapshot baseline.
- [[botster plugin entity hydration has full id and scoped contracts]] — `entity_upsert` merges one record into a family that a snapshot established.
- [[botster plugin entity providers must replay after entity broadcast reload]] — provider availability sits under every hydration contract.
- [[botster workspace records are plugin owned references not hub authority]] — plugin persistence owns the records; the Hub only fans frames out.
- Hub contract sources: `botster-hub/docs/lua-plugin-abi.md` ("Live mutation publish") and `botster-hub/docs/plans/package-entity-mutation-fanout-and-empty-snapshot-array-encoding.md` (admission table, family floor, pending window W=16, resync).
- Prior art: `botster-workspaces/plugin.lua` membership publish (persisted `next_seq` counter, same-batch reservation, one retry, degraded delivery) and `botster-workspaces/test/plugin_runtime_test.lua` (stub-loaded runtime harness with forced publish failure).

Runtime-teardown class: **does not apply**. This ticket changes durable-state publish plumbing inside the plugin worker. It has no WebRTC/peer lifecycle, no SessionIo/ClientWorker teardown, no multi-peer ownership, and no CPU/FD spin surface.

## Context loaded

- Ticket, run, gates, and empty checklist/artifact state from `project_pipelines_current_context`.
- `plugin.lua` at `beaba94`: `save_state` (lines 573–693) is the single durable-write choke point. It already diffs every family against `_originals` and collects `mutation_records` entries (`family`, `id`, `record`) for exactly the changed and deleted rows.
- `record_question` (1575), `answer_question` (1629), and the session activation path (1441–1551) all mutate through `save_state`. The activation path saves twice: once with status `spawning`, once with the spawn result including `session_id`.
- `ENTITY_PROVIDER_FAMILIES` (3253) registers 19 snapshot-only providers. `entity_provider_handler` (3277) allocates `snapshot_seq` from the in-memory `entity_snapshot_sequences` table, which resets on plugin reload.
- Hub `main` commit `3a5e754` ("package entity mutation fanout") is an ancestor of the pinned `EXPECTED_HUB_COMMIT d52c3ebc`. The pinned Hub already provides `botster.entity_publish`. **No Hub pin advance and no cross-repository dependency are required.**
- `botster.entity_publish` needs no manifest capability: botster-workspaces publishes with the same capability set this package already declares.
- Test surfaces: `script/test` (npm ui-contract pin + Python manifest/source asserts), `script/test-hub-flow` (Ruby, real pinned Hub, socket protocol v6, holds entity subscriptions, has `subscribe_entity_snapshot` for `project-pipelines.question`), `script/hub_acceptance_smoke`. `lua` is available on PATH; workspaces runs its stub harness with plain `lua`.

## Scope

1. **Persisted per-family publish sequence for the two published families.** Add two durable counter keys, `v4/meta/entity_seq/question` and `v4/meta/entity_seq/session_request`, payload `{ next_seq = N }`, guarded by `expected_revision` CAS. `load_state` reads both counters and revisions into `state._entity_seq`.
2. **Publish seam inside `save_state`.** After the atomic batch succeeds:
   - For each `mutation_records` entry in family `questions` or `session_requests`, publish one `entity_upsert` on `project-pipelines.question` / `project-pipelines.session_request` with the record copy (no `_store_position`) — the same row shape the snapshot provider returns.
   - For each deleted record in those families, publish one `entity_remove` (the shared helper makes this free).
   - Reserve the needed sequence values by adding the counter mutation(s) to the **same batch** as the durable mutation. Frames use `last_seq + 1 .. last_seq + count` in mutation order.
   - First-write key accounting mirrors the existing `meta/counters` handling in the `projected_keys` computation.
   - `mutation_records` already contains only changed rows (deep-equal diff), so "publish only changed records" holds structurally. No snapshot republish on mutation.
3. **Failure policy (parity with event admission failure).** `result.ok == true` (`accepted`, `pending_gap`, `resync_scheduled`) is admitted. On `botster.entity_publish` missing, pcall error, or `ok == false`: retry that frame once; if still failing, keep the durable mutation committed, keep `save_state` returning success, and record one bounded `entity_publish_degraded` event in the durable `events` family (MAX_EVENTS = 256 cap) with `{family, id, snapshot_seq, code, bounded message}` through one guarded follow-up batch. A re-entry guard keeps the diagnostic save from publishing or recursing. If the diagnostic save itself fails, drop it silently. Tool results never change shape and never fail because of publish.
4. **Provider sequence coordination for the two published families only.** The `question` and `session_request` providers allocate `snapshot_seq` from the same persisted counter via CAS advance-by-one with retry (the workspaces `membership_entity_provider` pattern: read counter, load rows, re-read counter, CAS, retry on conflict). The other 17 providers keep the in-memory counter and stay byte-unchanged.
5. **Docs.** Document the live-mutation publish contract for the two families in `README.md`.
6. **Tests.** New stub-loaded `test/plugin_runtime_test.lua` wired into `script/test`; live-path extension of `script/test-hub-flow` (details under acceptance checks).

### Why the provider sequence must move (ticket-intent note)

The ticket says "keep the existing per-family snapshot providers unchanged as the baseline hydration path." I read "unchanged" as the providers remain the baseline hydration mechanism, not as byte-identical sequence code, because the Hub keeps **one** monotonic family floor: `last_accepted_seq = max(published seqs, provider snapshot seqs)`. Once mutations publish from a persisted counter, an in-memory provider counter (reset to 1 on reload) would emit snapshots behind the floor forever. New subscribers would stay `catching_up`, resync would degrade after 8 attempts, and the baseline hydration path — which the ticket explicitly requires to keep working — would break. Sharing the persisted counter is the smallest change that satisfies both acceptance lines simultaneously, and it is the exact botster-workspaces production pattern.

## Non-scope

- No mutation publishing for the other 17 families. The shared helper is keyed by an explicit published-family set; extending it later is one table entry per family plus provider seq coordination, which is **not** free, so it stays out.
- No Hub, Core, TUI, or Web changes. The consumer TUI ticket `ticket_1786663585_944018` stays a separate run.
- No `entity_patch` frames; full-row `entity_upsert` only.
- No manifest capability changes, no package version bump, no UI/surface changes, no schema-version bump (the two meta keys are additive under `v4/`).
- No change to the transient `question.opened` event or to any tool result shape.
- No pull request; delivery policy is direct merge to main after verification.

## Ownership boundaries and cross-repo dependencies

| Layer | Owns |
| --- | --- |
| **botster-project-pipelines** (this run) | Durable records, persisted sequence counters, publish-after-commit seam, degraded diagnostics, provider truth, package tests |
| **botster-hub** | `entity_publish` admission, family floor, pending window, fanout, provider resync — already merged at the pinned `d52c3ebc` (contains `3a5e754`) |
| **botster-workspaces** | Prior art only; not touched |
| **botster-tui** | Consumer ticket `ticket_1786663585_944018` builds its question/attention UI on this surface after this run merges |

No blocking dependency registration is needed: the only upstream mechanism (Hub fanout) is already inside the existing pinned Hub commit that `script/test-hub-flow` builds.

## Assumptions and unknowns

Assumptions:
1. "Providers unchanged" means unchanged as the baseline hydration mechanism; the two published families' sequence source must move to the shared persisted counter (argued above). If Plan Review reads the ticket as byte-frozen providers, this needs a human ruling, because the two readings cannot both converge under the Hub floor contract.
2. The plugin worker serializes invocations (ABI: providers run "through its isolated plugin worker"), so counter CAS conflicts cannot occur inside one process; CAS remains as defense in depth and the provider retries on conflict.
3. After a Hub restart the in-memory family floor resets while the persisted counter keeps rising. The first post-restart publish lands outside the pending window, returns `resync_scheduled` (`ok=true`), and the provider resync converges subscribers. This is designed Hub behavior, not a defect.
4. `entity_remove` frame shape is `{type, entity_type, snapshot_seq, id}` per the ABI publish example.

Unknowns for Implement to confirm:
1. Exact `entity_remove` field set against Hub tests (`hub_daemon_lifecycle_test` upsert-then-remove test).
2. Whether `script/test`'s Python source asserts or `hub_acceptance_smoke` tree asserts pin any string the change touches; keep both green.
3. Whether any code path deletes question or session_request records today; the remove branch is covered by the shared helper either way.

## Affected surfaces/files

- `plugin.lua` — store constants (two meta keys, published-family set), `load_state` (read seq counters), `save_state` (same-batch seq reservation, post-commit publish, degraded diagnostic with re-entry guard, first-write key accounting), `entity_provider_handler` split for the two persisted-seq families.
- `test/plugin_runtime_test.lua` — **new** stub-loaded Lua runtime harness (workspaces pattern: fake `plugin_db` with revisions, stub `botster.entity_publish`, `events`, `botster.register` returning the descriptor).
- `script/test` — run `lua test/plugin_runtime_test.lua`.
- `script/test-hub-flow` — held-open subscription checks (below).
- `README.md` — live mutation publish contract for the two families.

## Risks

| Risk | Mitigation |
| --- | --- |
| Provider snapshots and published deltas diverge on one family floor | One persisted counter per published family shared by both allocators; live floor check in test-hub-flow |
| Seq-counter CAS conflict fails the whole durable batch | Worker serialization makes it unreachable in-process; provider retries on `revision_conflict`; runtime test seeds a conflict |
| Publish failure loops or double-writes diagnostics | One retry per frame; re-entry guard on the diagnostic save; diagnostic save failure drops silently |
| Two saves in activation publish two session_request frames | Correct by contract: subscribers see `spawning` then `spawn_requested` with `session_id` |
| Store key ceiling accounting drifts | Mirror the existing `meta/counters` first-write accounting; two keys against a 1024 cap |
| Large `session_request.request`/`result` envelopes in frames | Same row shape snapshots already deliver; `bounded_prompt` already bounds the prompt copy |
| Contract-pinning asserts in `script/test` / smoke break | Run both scripts before gates; update asserts only where the pinned string changed |

## Acceptance checks/tests

Runtime harness (`lua test/plugin_runtime_test.lua`, run by `script/test`):
1. `record_question` commit publishes one `entity_upsert` on `project-pipelines.question` with the new row and `snapshot_seq = last + 1`; the counter mutation is in the same batch.
2. `answer_question` publishes the changed question row (status `answered`, `answer_id` set); unchanged families publish nothing.
3. Session activation publishes `spawning` then `spawn_requested` upserts; the second carries `session_id`.
4. Forced failure: stub `entity_publish` errors (and separately returns `ok=false, status=stale_sequence`) twice → durable record committed, tool result `ok`, one bounded `entity_publish_degraded` event recorded, no recursion.
5. `ok=true` non-accepted statuses (`pending_gap`, `resync_scheduled`) are treated as admitted: no retry storm, no diagnostic.
6. Provider CAS: question provider snapshot allocates `last + 1` and retries once on a seeded revision conflict.
7. Record deletion in a published family emits `entity_remove`.
8. A mutation in a non-published family (for example `artifacts`) publishes nothing.

Live proof (`script/test-hub-flow` against pinned Hub `d52c3ebc`, real socket, public MCP tools):
9. Open a held subscription to `project-pipelines.question` **before** calling the ask-human tool; the subscription receives the new question row as `entity_upsert` without resubscribing.
10. Answer the question; the **same** held subscription receives the status-change upsert. (This pair is the downstream proof the TUI consumer ticket `ticket_1786663585_944018` requires.)
11. Open a held subscription to `project-pipelines.session_request`; run a spawn; the subscription receives the correlation row including `session_id`.
12. Existing snapshot checks stay green, and a fresh subscribe after the mutations returns a complete baseline whose `snapshot_seq` is at or above the published floor.

Repository gates:
13. `script/test` passes end to end.
14. `script/test-hub-flow` passes end to end (includes the existing restart-recovery question check).
15. `script/hub_acceptance_smoke` stays green (run; extend only if its pinned asserts intersect the change).

Production entry-point proof: checks 9–11 drive `project_pipelines_ask_human` / answer / spawn through the real pinned Hub daemon socket into `record_question` → `save_state` → `botster.entity_publish`, so the production path itself is exercised, not just library code.

## Vault gaps

Capture after Implement/Verify:
1. Pattern: published plugin entity families share one persisted sequence between provider snapshots and mutation publishes (generalizes the workspaces membership note to a second production user).
2. Gotcha: Hub restart resets in-memory family floors while persisted package counters keep rising; the first post-restart publish converges through `resync_scheduled`, not `accepted`.
3. Convention: this repository stores plan artifacts at `docs/plans/` (adopted here from sibling-repo pipeline prior art; no prior in-repo authority existed).

## Product decision ledger

| Item | Decision |
| --- | --- |
| Publish seam | Inside `save_state` after batch success — every mutation path covered once |
| Sequence source | Persisted per-family counter, same-batch reservation, CAS |
| Provider seq for published families | Shared persisted counter via CAS advance-by-one |
| Failure policy | One retry per frame, then committed + success + bounded durable `entity_publish_degraded` event |
| Remove frames | Published for the two families (free via the shared helper) |
| Other families | Not published; explicit set, not manifest-driven |
| Version/manifest | Unchanged |

## Completion evidence (this Plan visit)

- `plan_uri`: `docs/plans/publish-live-entity-mutations-for-question-and-session-request.md`
- `artifact_id`: set by `project_pipelines_add_artifact` on this visit
- `checklist_id`: set by the vault checklist created on this visit
- `target_id`: `tgt_a72ca1a83d504385b8648f71409119ab`
- `target_repository`: `botster-project-pipelines`
