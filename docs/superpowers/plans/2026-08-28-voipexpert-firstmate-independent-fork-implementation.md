# VoIP Expert FirstMate Independent Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `voipexpert/firstmate:main` the authoritative tested FirstMate release and deploy that exact release on the coding server without losing private runtime state or depending on upstream approval.

**Architecture:** Build an isolated integration branch from `voipexpert/firstmate:main`, merge the completed automatic-dispatch branch without rewriting it, and preserve both upstream supervision changes and the new routing controls in the two conflicting files. Verify the exact merge commit, advance the fork's `main` only after the captain's merge gate, tag it, then fast-forward the existing coding-server checkout while proving its private and untracked material remains in place.

**Tech Stack:** Git worktrees, GitHub CLI, Bash, tmux, FirstMate's shell test runner, ShellCheck, actionlint, Claude Code, Pi, Codex, and quota-axi.

## Global Constraints

- `voipexpert/firstmate:main` is the writable authoritative branch.
- `kunchenguid/firstmate` is retained only as a read-only upstream reference.
- Never rebase or force-push `feat/firstmate-optimization-design`.
- Never merge or update the fork's `main` without the captain's explicit merge approval at Task 4.
- Never stash, delete, overwrite, or move existing material under `/home/yaro/work/firstmate` to make deployment succeed.
- Preserve all gitignored `config/`, `data/`, and `state/` content and every current untracked operational artifact.
- If a target tracked path collides with any current untracked or ignored path, stop before deployment and use a new code checkout with the existing `FM_HOME` instead.
- Automatic production routing remains off; repository integration does not authorize simulation, canary, or automatic rollout.
- Do not commit API keys, account maps, credentials, routing policy, circuit state, prompts, source payloads, or raw tool output.
- Run the complete verification gate against the exact merge commit before updating the fork's `main`.
- Keep the feature and integration worktrees until deployment and rollback verification are complete.
- Restart the active `firstmate` tmux session only after the captain explicitly approves the cutover and the current session has completed `/stow`.

---

## File Structure

### Existing files resolved during integration

- `bin/fm-spawn.sh` must contain both upstream supervision-branch lease enforcement and the feature's policy-bound routing admission, account-lane binding, relaunch, and cleanup behavior.
- `bin/fm-test-run.sh` must contain the union of upstream test-family additions and the automatic-dispatch test-family and changed-path mappings.

### Existing files used as verification contracts

- `tests/fm-branch-supervision.test.sh` verifies upstream role partitioning around fresh spawns and relaunches.
- `tests/fm-spawn-pool-base-freshen.test.sh` verifies upstream stale-submodule diagnostics and conservative refusal.
- `tests/fm-spawn-dispatch-profile.test.sh` verifies policy-bound routed launches.
- `tests/fm-route.test.sh` verifies deterministic routing, capacity, circuit, privacy, and recovery behavior.
- `tests/fm-test-run.test.sh` and `bin/fm-test-run.sh --check-coverage` verify the merged test inventory and family map.
- `docs/superpowers/specs/2026-08-28-voipexpert-firstmate-independent-fork-design.md` remains the authoritative design contract.

### Operational paths created outside tracked source

- `/home/yaro/work/firstmate-migration/2026-08-28/` stores mode-0700 preflight and deployment evidence without placing private inventory in Git.
- `/home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0/` is the isolated integration worktree.

---

### Task 1: Capture Preflight State and Create the Isolated Integration Worktree

**Files:**

- Create outside Git: `/home/yaro/work/firstmate-migration/2026-08-28/preflight.txt`
- Create outside Git: `/home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.before`
- Create worktree: `/home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0/`

**Interfaces:**

- Consumes: local branch `feat/firstmate-optimization-design`, remote branch `fork/main`, and runtime checkout `/home/yaro/work/firstmate`.
- Produces: branch `integration/voipexpert-v1.0.0` based exactly on `fork/main` and a private before-state inventory.
- Preserves: the live `firstmate` tmux session and every existing worktree.

- [ ] **Step 1: Verify the expected source commits and clean feature worktree.**

Run:

```bash
cd /home/yaro/work/firstmate/.worktrees/firstmate-optimization-design
git fetch fork main
git status --short --branch
git rev-parse feat/firstmate-optimization-design
git rev-parse fork/main
git merge-base feat/firstmate-optimization-design fork/main
```

Expected: the feature worktree has no uncommitted changes, the feature head includes commit `05853cd`, and `fork/main` resolves to a commit. Record the three exact hashes in the execution report; do not hard-reset either branch if a hash has moved.

- [ ] **Step 2: Capture private preflight evidence without reading file contents.**

Run:

```bash
install -d -m 700 /home/yaro/work/firstmate-migration/2026-08-28
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  git -C /home/yaro/work/firstmate rev-parse HEAD
  git -C /home/yaro/work/firstmate status --short --branch
  git -C /home/yaro/work/firstmate remote -v
  git -C /home/yaro/work/firstmate worktree list --porcelain
  tmux list-panes -t firstmate -F 'session=#{session_name} cwd=#{pane_current_path} command=#{pane_current_command} dead=#{pane_dead} pid=#{pane_pid}'
} > /home/yaro/work/firstmate-migration/2026-08-28/preflight.txt
git -C /home/yaro/work/firstmate status --porcelain=v1 --ignored -uall > /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.before
chmod 600 /home/yaro/work/firstmate-migration/2026-08-28/preflight.txt /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.before
```

Expected: both files are owned by `yaro`, mode `0600`, and the tmux pane remains alive with `cwd=/home/yaro/work/firstmate`.

- [ ] **Step 3: Preview the merge and require exactly the known conflict set.**

Run:

```bash
cd /home/yaro/work/firstmate/.worktrees/firstmate-optimization-design
git merge-tree --write-tree --name-only --messages fork/main feat/firstmate-optimization-design 2>&1 | tee /home/yaro/work/firstmate-migration/2026-08-28/merge-preview.txt
grep '^CONFLICT (content):' /home/yaro/work/firstmate-migration/2026-08-28/merge-preview.txt
```

Expected: content conflicts are reported only for `bin/fm-spawn.sh` and `bin/fm-test-run.sh`. Stop and revise the plan if any additional conflict appears.

- [ ] **Step 4: Create the isolated integration worktree.**

Run:

```bash
git -C /home/yaro/work/firstmate worktree add -b integration/voipexpert-v1.0.0 /home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0 fork/main
git -C /home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0 status --short --branch
```

Expected: a clean named-branch worktree tracking `fork/main`; the runtime checkout and feature worktree remain unchanged.

---

### Task 2: Merge the Feature and Resolve the Two Conflicts Without Losing Either Safety Model

**Files:**

- Modify through merge resolution: `bin/fm-spawn.sh`
- Modify through merge resolution: `bin/fm-test-run.sh`

**Interfaces:**

- Consumes: upstream lease functions from `bin/fm-lease-lib.sh` and routing interfaces from `bin/fm-route.sh` and `bin/fm-account-lane.sh`.
- Produces: one merge commit whose first parent is `fork/main` and second parent is `feat/firstmate-optimization-design`.
- Preserves: upstream stale-submodule refusal and all feature route-admission invariants.

- [ ] **Step 1: Start the non-rewriting merge and confirm the expected unresolved files.**

Run:

```bash
cd /home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0
git merge --no-ff --no-commit feat/firstmate-optimization-design
git diff --name-only --diff-filter=U
```

Expected: Git stops with exactly `bin/fm-spawn.sh` and `bin/fm-test-run.sh` unresolved. Do not use `git checkout --ours` or `git checkout --theirs` on either whole file.

- [ ] **Step 2: Resolve the `fm-spawn.sh` post-ID-validation overlap in this exact order.**

The merged block immediately after `ID=${POS[0]}` must retain this ordering:

```bash
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$RELAUNCH" -ne 1 ]; then
  fm_lease_forbid_branch "new-task spawn (fm-spawn)"
fi
if [ "$KIND" = secondmate ] && [ "$ROUTE_FLAGS_PRESENT" = 1 ] \
  && [ "$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)" = 1 ]; then
  echo "error: route flags are unsupported for remote secondmate launches" >&2
  exit 1
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$ROUTE_REQUESTED" = 1 ]; then
  ROUTE_ACTIVE=1
  ROUTE_LAUNCH_HARNESS=$HARNESS_ARG
  ROUTE_LAUNCH_MODEL=$MODEL
  [ "$EFFORT_SET" -eq 0 ] || ROUTE_LAUNCH_EFFORT=$EFFORT
  spawn_route_begin fresh || exit 1
fi
```

Inside the existing `if [ "$RELAUNCH" -eq 1 ]` lock-owner chain, retain the upstream branch-actor refusal between the control-parent and lock-acquisition arms:

```bash
if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
  SPAWN_CONTROL_PARENT=1
elif [ "$(fm_lease_actor)" = branch ]; then
  echo "error: relaunch (fm-spawn) refused - the supervision branch must relaunch through fm-control" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
elif fm_lock_try_acquire "$SPAWN_CONTROL_LOCK"; then
  SPAWN_CONTROL_LOCK_HELD=1
```

Retain the upstream `describe_stale_submodule_pins` function and its `freshen_spawn_worktree_base` call unchanged. Retain every route tuple parser, `spawn_route_begin`, route-account binding, route metadata publication, admission commit, and abort-cleanup block from the feature side.

- [ ] **Step 3: Resolve `fm-test-run.sh` as a union, never by choosing one side.**

Ensure the final family map contains all automatic-dispatch entries:

```text
fm-account-lane.test.sh
fm-automatic-dispatch-contract.test.sh
fm-automatic-dispatch-live-e2e.test.sh
fm-automatic-dispatch-live-guard.test.sh
fm-bootstrap-dispatch-policy.test.sh
fm-dispatch-policy.test.sh
fm-route.test.sh
```

Also retain all new upstream entries, including:

```text
fm-task-inbox.test.sh
fm-remote-transport-lanes.test.sh
fm-secondmate-reconcile.test.sh
fm-bootstrap-network-parallel.test.sh
fm-pi-branch-live-e2e.test.sh
fm-send-inbox-doorbell-live-e2e.test.sh
fm-send-inbox.test.sh
fm-bearings-board-render.test.sh
```

Retain feature changed-path mappings for `bin/fm-route.sh`, `bin/fm-routing-lib.sh`, `bin/fm-account-lane.sh`, and `bin/fm-dispatch-policy.sh`, plus upstream's `bin/fm-task-inbox-lib.sh` mapping.

- [ ] **Step 4: Prove all conflict markers are gone and run the combined focused contract.**

Run:

```bash
git diff --check
! grep -RInE '^(<<<<<<<|=======|>>>>>>>)' bin/fm-spawn.sh bin/fm-test-run.sh
bash -n bin/fm-spawn.sh bin/fm-test-run.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh tests/fm-spawn-pool-base-freshen.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-route.test.sh tests/fm-test-run.test.sh
bin/fm-test-run.sh --check-coverage
```

Expected: five focused tests pass, coverage reports every merged test exactly once, and no conflict marker or syntax error remains.

- [ ] **Step 5: Commit the merge without rewriting either parent.**

Run:

```bash
git add bin/fm-spawn.sh bin/fm-test-run.sh
git status --short
git commit -m "merge: integrate subscription-first dispatch"
git rev-list --parents -n 1 HEAD
```

Expected: the commit has exactly two parents, the first is the Task 1 `fork/main` hash, and the second is the feature head containing `05853cd`.

---

### Task 3: Verify the Exact Integration Commit

**Files:**

- Test only: complete merged repository
- Create outside Git: `/home/yaro/work/firstmate-migration/2026-08-28/*.json`

**Interfaces:**

- Consumes: the Task 2 merge commit.
- Produces: lint, coverage, isolated, host-sensitive, portable-serial, and non-mutating live evidence bound to one exact SHA.
- Does not produce: routing reservations, spawned workers, or production policy changes.

- [ ] **Step 1: Run formatting, syntax, and inventory gates.**

Run:

```bash
cd /home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0
git diff --check fork/main...HEAD
bin/fm-lint.sh
bin/fm-test-run.sh --check-coverage
```

Expected: ShellCheck and actionlint pass, the diff is whitespace-clean, and every test is mapped exactly once.

- [ ] **Step 2: Run the exact six host-sensitive regression tests.**

Run:

```bash
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-on.test.sh tests/fm-remote-doctor.test.sh tests/fm-session-start.test.sh tests/fm-tmux-agent-liveness.test.sh --json /home/yaro/work/firstmate-migration/2026-08-28/integration-six.json
```

Expected: `FM_TEST_SUMMARY total=6 failed=0`; declared optional gates may skip, but no test may fail.

- [ ] **Step 3: Run the proven-isolated parallel gate.**

Run:

```bash
bin/fm-test-run.sh --proven-isolated --jobs 4 --json /home/yaro/work/firstmate-migration/2026-08-28/integration-isolated.json
```

Expected: every proven-isolated test passes with `failed=0`.

- [ ] **Step 4: Run the complete portable serial gate once.**

Run:

```bash
bin/fm-test-run.sh --lane portable-serial --json /home/yaro/work/firstmate-migration/2026-08-28/integration-portable-serial.json
```

Expected: the complete merged inventory finishes with `failed=0`. Optional harness and binary gates may report their declared skips.

- [ ] **Step 5: Run the non-mutating live automatic-dispatch smoke.**

Run:

```bash
FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-automatic-dispatch-live-e2e.test.sh --json /home/yaro/work/firstmate-migration/2026-08-28/integration-live-e2e.json
```

Expected: Claude, Codex, Pi, configured Pi model aliases, and quota-axi probes pass without calling `fm-spawn.sh`, creating routing state, or installing a policy.

- [ ] **Step 6: Bind the evidence to the exact commit.**

Run:

```bash
git rev-parse HEAD | tee /home/yaro/work/firstmate-migration/2026-08-28/verified-sha.txt
git status --short --branch
```

Expected: the integration worktree is clean and the recorded SHA is the Task 2 merge commit.

---

### Task 4: Review, Obtain the Merge Gate, Advance the Fork, and Tag the Release

**Files:**

- No source changes expected.
- Update remote refs: `voipexpert/firstmate:integration/voipexpert-v1.0.0`, `voipexpert/firstmate:main`, and tag `voipexpert-v1.0.0`.

**Interfaces:**

- Consumes: the exact green SHA from Task 3 and an independent final review.
- Produces: an authoritative fork `main` and immutable internal release tag at that same SHA.
- Requires: a fresh, explicit captain instruction to merge after review results are reported.

- [ ] **Step 1: Push only the integration branch for review.**

Run:

```bash
cd /home/yaro/work/firstmate/.worktrees/voipexpert-v1.0.0
git push -u fork integration/voipexpert-v1.0.0
```

Expected: the fork's `main` and tags remain unchanged.

- [ ] **Step 2: Perform independent review of the merged diff.**

Review:

```bash
git diff --stat fork/main...HEAD
git diff fork/main...HEAD -- bin/fm-spawn.sh bin/fm-test-run.sh
git log --oneline --decorate --graph --max-count=60
```

The reviewer must explicitly verify that upstream lease partitioning and stale-submodule refusal survive, route admission remains policy-bound and fail-closed, the test-family map is a complete union, no secret-bearing file is tracked, and the Task 3 evidence matches `HEAD`.

Expected: no Critical, Important, or Minor findings. Any finding returns to Task 2, receives a focused regression test where behavior changed, and reruns the affected Task 3 gates.

- [ ] **Step 3: Stop at the captain's merge gate.**

Report the reviewed SHA, verification totals, review findings, and the exact pending operation:

```text
Advance voipexpert/firstmate:main from its current SHA to the verified integration SHA and create tag voipexpert-v1.0.0.
```

Expected: no push to `main` and no tag until the captain explicitly approves that exact operation.

- [ ] **Step 4: After explicit approval, fast-forward the fork's `main`.**

Run:

```bash
VERIFIED_SHA=$(cat /home/yaro/work/firstmate-migration/2026-08-28/verified-sha.txt)
test "$(git rev-parse HEAD)" = "$VERIFIED_SHA"
git fetch fork main
git merge-base --is-ancestor fork/main "$VERIFIED_SHA"
git push fork "$VERIFIED_SHA":refs/heads/main
test "$(git ls-remote fork refs/heads/main | awk '{print $1}')" = "$VERIFIED_SHA"
```

Expected: the update is fast-forward-only and remote `main` equals the verified SHA. Never add `--force` or `--force-with-lease`.

- [ ] **Step 5: Create and push the internal release tag.**

Run:

```bash
test -z "$(git ls-remote --tags fork refs/tags/voipexpert-v1.0.0)"
git tag -a voipexpert-v1.0.0 "$VERIFIED_SHA" -m "VoIP Expert FirstMate v1.0.0"
git push fork refs/tags/voipexpert-v1.0.0
test "$(git rev-list -n 1 voipexpert-v1.0.0)" = "$VERIFIED_SHA"
```

Expected: the annotated tag resolves to the same verified SHA as fork `main`.

---

### Task 5: Convert the Coding-Server Checkout to the Canonical Fork and Deploy by Fast-Forward

**Files:**

- Modify Git metadata only: `/home/yaro/work/firstmate/.git/config`
- Update tracked checkout: `/home/yaro/work/firstmate/`
- Preserve private paths: `/home/yaro/work/firstmate/config/`, `/home/yaro/work/firstmate/data/`, `/home/yaro/work/firstmate/state/`, and existing untracked artifacts.

**Interfaces:**

- Consumes: `voipexpert/firstmate:main` and tag `voipexpert-v1.0.0` from Task 4.
- Produces: local `main` tracking the VoIP Expert fork and an `upstream` remote pointing at the original project.
- Preserves: the current tmux process while code is updated on disk.

- [ ] **Step 1: Refuse deployment if tracked or path-collision preconditions fail.**

Run:

```bash
cd /home/yaro/work/firstmate
test -z "$(git status --porcelain --untracked-files=no)"
git fetch fork main
git merge-base --is-ancestor main fork/main
comm -12 \
  <(git ls-tree -r --name-only fork/main | sort) \
  <({ git ls-files --others --exclude-standard; git ls-files --others --ignored --exclude-standard; } | sort -u) \
  | tee /home/yaro/work/firstmate-migration/2026-08-28/path-collisions.txt
test ! -s /home/yaro/work/firstmate-migration/2026-08-28/path-collisions.txt
```

Expected: no tracked modification, local `main` is an ancestor of fork `main`, and the collision file is empty. If any check fails, stop without changing remotes or branches.

- [ ] **Step 2: Rename remotes to express ownership.**

Run:

```bash
git remote rename origin upstream
git remote rename fork origin
git remote -v
```

Expected:

```text
origin   https://github.com/voipexpert/firstmate.git
upstream https://github.com/kunchenguid/firstmate.git
```

The authenticated `voipexpert` identity has write access to `origin` and only read access to `upstream`.

- [ ] **Step 3: Fast-forward the existing local `main` and set its authoritative tracking branch.**

Run:

```bash
git fetch origin main --tags
git merge --ff-only origin/main
git branch --set-upstream-to=origin/main main
test "$(git rev-parse HEAD)" = "$(git rev-parse voipexpert-v1.0.0)"
```

Expected: no merge conflict, no local merge commit, and local `HEAD`, `origin/main`, and `voipexpert-v1.0.0` are identical.

- [ ] **Step 4: Prove private and untracked path inventory survived.**

Run:

```bash
git status --porcelain=v1 --ignored -uall > /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.after
chmod 600 /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.after
cmp /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.before /home/yaro/work/firstmate-migration/2026-08-28/runtime-paths.after
for path in config data state briefs reports; do
  test -e "/home/yaro/work/firstmate/$path" && printf 'preserved %s\n' "$path"
done
```

Expected: the complete status inventory is byte-identical and every previously present private path remains present. Do not delete files merely because Git reports them as ignored or untracked.

- [ ] **Step 5: Run the deployed-checkout smoke without enabling routing.**

Run:

```bash
test ! -e /home/yaro/work/firstmate/config/crew-dispatch.json
/home/yaro/work/firstmate/bin/fm-dispatch-policy.sh validate /home/yaro/work/firstmate/docs/examples/crew-dispatch.json
/home/yaro/work/firstmate/bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh tests/fm-route.test.sh tests/fm-spawn-dispatch-profile.test.sh
```

Expected: the tracked example and focused deployed tests pass, while the private production policy remains absent and no routing state is created.

---

### Task 6: Perform a Controlled FirstMate Session Cutover

**Files:**

- Runtime only: tmux session `firstmate`
- Preserve: `/home/yaro/work/firstmate/data/`, `/home/yaro/work/firstmate/state/`, and the existing Claude conversation until `/stow` completes.

**Interfaces:**

- Consumes: deployed tagged checkout from Task 5.
- Produces: a fresh Claude Code primary session started from the exact tagged checkout.
- Requires: explicit captain approval to restart the active session after `/stow` has completed.

- [ ] **Step 1: Verify the active session and ask the captain to run `/stow`.**

Run:

```bash
tmux list-panes -t firstmate -F 'cwd=#{pane_current_path} command=#{pane_current_command} dead=#{pane_dead} pid=#{pane_pid}'
```

Expected: one live pane with `cwd=/home/yaro/work/firstmate` and `command=claude.real` or the currently approved Claude launcher. Ask the captain to complete `/stow`; do not synthesize completion from a quiet pane.

- [ ] **Step 2: Stop at the restart gate.**

Report that code and tag are deployed but the existing agent context still has the old startup instructions. Request the exact approval: restart tmux session `firstmate` now.

Expected: no exit, signal, kill, or tmux mutation before explicit approval.

- [ ] **Step 3: After approval, request graceful exit and refuse forced termination.**

Run:

```bash
tmux send-keys -t firstmate:0.0 '/exit' Enter
for attempt in 1 2 3 4 5 6; do
  tmux has-session -t firstmate 2>/dev/null || break
  sleep 5
done
! tmux has-session -t firstmate 2>/dev/null
```

Expected: Claude exits and the tmux session disappears within 30 seconds. If it remains, stop and ask the captain; do not use `tmux kill-session`, `kill`, or `kill -9`.

- [ ] **Step 4: Start the new primary session from the tagged checkout.**

Run:

```bash
cd /home/yaro/work/firstmate
test "$(git rev-parse HEAD)" = "$(git rev-list -n 1 voipexpert-v1.0.0)"
tmux new-session -d -s firstmate -c /home/yaro/work/firstmate 'claude'
sleep 10
tmux list-panes -t firstmate -F 'cwd=#{pane_current_path} command=#{pane_current_command} dead=#{pane_dead} pid=#{pane_pid}'
tmux capture-pane -pt firstmate:0.0 -S -120
```

Expected: the pane is alive in `/home/yaro/work/firstmate`, Claude is running, and the FirstMate session-start digest completes without a repository, policy, quota, or session-lock error.

- [ ] **Step 5: Verify static behavior and release identity after cutover.**

Run:

```bash
git -C /home/yaro/work/firstmate status --short --branch
git -C /home/yaro/work/firstmate describe --tags --exact-match HEAD
test ! -e /home/yaro/work/firstmate/config/crew-dispatch.json
test ! -d /home/yaro/work/firstmate/state/routing
```

Expected: local `main` tracks `origin/main`, the exact tag is `voipexpert-v1.0.0`, and no production routing policy or routing-state directory exists.

---

## Specification Coverage

- Task 1 covers isolation, exact source provenance, private preflight evidence, and preservation of existing worktrees and the live session.
- Task 2 covers non-rewriting integration and deterministic preservation of both upstream supervision safety and subscription-first routing safety.
- Task 3 covers lint, coverage, host-sensitive, isolated, complete portable, and live non-mutating verification at one exact SHA.
- Task 4 covers independent review, explicit merge authority, authoritative fork `main`, and immutable internal release tagging.
- Task 5 covers canonical remote ownership, safe fast-forward deployment, untracked/private-state preservation, and static-mode smoke tests.
- Task 6 covers durable session handoff, explicit restart authority, graceful-only termination, startup verification, and proof that automatic production routing remains off.
- Selective upstream intake remains a future operational workflow; no automatic synchronization is introduced by this plan.

## Final Review Checklist

- [ ] The feature branch history was not rebased or force-pushed.
- [ ] The merge preview and real merge had only the two expected conflict files.
- [ ] `fm-spawn.sh` retains upstream branch-lease and stale-submodule protections.
- [ ] `fm-spawn.sh` retains complete fail-closed route admission, account binding, relaunch, metadata, and abort cleanup.
- [ ] `fm-test-run.sh` contains the union of upstream and automatic-dispatch mappings.
- [ ] Every verification artifact is bound to the exact merge SHA.
- [ ] The fork's `main` was untouched before explicit captain approval.
- [ ] `voipexpert-v1.0.0`, fork `main`, and deployed local `HEAD` resolve to one SHA.
- [ ] `origin` is the VoIP Expert fork and `upstream` is the original repository.
- [ ] Runtime private and untracked inventory is unchanged across deployment.
- [ ] The existing tmux session was not force-terminated.
- [ ] The restarted FirstMate session loaded successfully from the tagged checkout.
- [ ] No private production dispatch policy or routing state was created.
- [ ] Upstream PR acceptance is not required for use of the deployed system.
