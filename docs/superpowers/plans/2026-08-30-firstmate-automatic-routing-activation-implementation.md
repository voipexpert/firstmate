# FirstMate Automatic Routing Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate FirstMate's deployed subscription router in automatic mode and prove that it retains the approved capacity and safety controls.

**Architecture:** Change only the live private policy on the coding server from `canary` to `automatic`.
Validate the existing routing implementation before and after the atomic policy patch, then perform a selection-only dry run that launches no worker.

**Tech Stack:** Bash, JSON, `jq`, FirstMate `bin/fm-route.sh`, and `tests/fm-route.test.sh`.

## Global Constraints

- Change only `routing.mode` from `canary` to `automatic`.
- Keep the automatic concurrency cap at six workers.
- Keep per-lane and per-account concurrency caps at two workers.
- Keep the burst ceiling at eight workers and require an explicit burst decision.
- Keep the circuit breaker at three failures in 900 seconds with a 1,800-second cooldown.
- Keep transient retries at one.
- Do not change profiles, routing rules, provider priorities, model aliases, credentials, authentication stores, or authority controls.
- Do not restart FirstMate if the routing status reflects the policy change immediately.
- Return the mode to `canary` if any post-change verification fails.

---

## File Structure

- Modify: `/home/yaro/work/firstmate/config/crew-dispatch.json`.
  This private policy owns the active routing mode and the existing limits.
- Verify: `/home/yaro/work/firstmate/bin/fm-route.sh`.
  This public command reports live routing state and performs a selection-only dry run.
- Test: `/home/yaro/work/firstmate/tests/fm-route.test.sh`.
  This behavioral suite verifies routing selection, capacity, circuit breakers, state handling, and validation.

No shared runtime source file changes are planned.

### Task 1: Activate and Verify Automatic Routing

**Files:**

- Modify: `/home/yaro/work/firstmate/config/crew-dispatch.json:4`
- Test: `/home/yaro/work/firstmate/tests/fm-route.test.sh`

**Interfaces:**

- Consumes: The version 2 private dispatch policy and the deployed `bin/fm-route.sh` command.
- Produces: Live routing status with `mode` equal to `automatic` and unchanged capacity and circuit-breaker values.

- [ ] **Step 1: Verify the pre-change policy and idle routing state**

Run:

```bash
cd /home/yaro/work/firstmate
test "$(jq -r '.routing.mode' config/crew-dispatch.json)" = canary
route_status=$(bin/fm-route.sh status)
jq -e '
  .mode == "canary"
  and .caps == {"canary":3,"automatic":6,"burst":8,"perLane":2,"perAccount":2}
  and .circuitBreaker == {"failures":3,"windowSeconds":900,"cooldownSeconds":1800}
  and .active.total == 0
  and .openCircuits == []
' <<<"$route_status" >/dev/null
```

Expected: Every command exits zero and no active routed worker or open circuit is reported.

- [ ] **Step 2: Run the focused routing regression suite before activation**

Run:

```bash
cd /home/yaro/work/firstmate
tests/fm-route.test.sh
```

Expected: The routing suite exits zero with all behavioral checks passing.

- [ ] **Step 3: Apply the one-field private policy change**

Run:

```bash
cd /home/yaro/work/firstmate
git apply --check <<'PATCH'
diff --git a/config/crew-dispatch.json b/config/crew-dispatch.json
--- a/config/crew-dispatch.json
+++ b/config/crew-dispatch.json
@@ -1,7 +1,7 @@
 {
   "schemaVersion": 2,
   "routing": {
-    "mode": "canary",
+    "mode": "automatic",
     "limits": {
       "canary": 3,
       "automatic": 6,
PATCH
git apply <<'PATCH'
diff --git a/config/crew-dispatch.json b/config/crew-dispatch.json
--- a/config/crew-dispatch.json
+++ b/config/crew-dispatch.json
@@ -1,7 +1,7 @@
 {
   "schemaVersion": 2,
   "routing": {
-    "mode": "canary",
+    "mode": "automatic",
     "limits": {
       "canary": 3,
       "automatic": 6,
PATCH
```

Expected: Both commands exit zero and only line 4 changes.

- [ ] **Step 4: Validate the activated policy and live status**

Run:

```bash
cd /home/yaro/work/firstmate
jq empty config/crew-dispatch.json
test "$(jq -r '.routing.mode' config/crew-dispatch.json)" = automatic
route_status=$(bin/fm-route.sh status)
jq -e '
  .mode == "automatic"
  and .caps == {"canary":3,"automatic":6,"burst":8,"perLane":2,"perAccount":2}
  and .circuitBreaker == {"failures":3,"windowSeconds":900,"cooldownSeconds":1800}
  and .active.total == 0
  and .openCircuits == []
' <<<"$route_status" >/dev/null
```

Expected: The policy parses and the live command immediately reports automatic mode with every approved bound unchanged.

- [ ] **Step 5: Perform a selection-only automatic routing dry run**

Run:

```bash
cd /home/yaro/work/firstmate
routing_profile=$(jq -r '.default[0]' config/crew-dispatch.json)
routing_decision=$(
  bin/fm-route.sh select \
    --request <(jq -n '{
      taskId:"automatic-activation-dry-run",
      taskClass:"standard",
      workType:"implementation",
      risk:"low",
      independent:false,
      requestedWorkers:1,
      requiredReasoningClass:"strong",
      estimatedSeconds:300
    }') \
    --candidates <(jq -c --arg profile "$routing_profile" '
      .profiles[$profile] as $candidate
      | [{
          profile:$profile,
          harness:$candidate.harness,
          model:$candidate.model,
          provider:$candidate.provider,
          lane:$candidate.lane,
          account:($candidate.account // "none"),
          fitTier:3,
          reasoningClass:$candidate.reasoningClass,
          catalogSupported:true,
          authState:"usable",
          spendPriority:1,
          runwaySeconds:3600,
          activeLane:0,
          historySuccesses:0,
          historyAttempts:0,
          costTier:null
        }]
    ' config/crew-dispatch.json)
)
jq -e --arg profile "$routing_profile" '
  .action == "selected"
  and .selected.profile == $profile
  and .maxWorkers == 1
' <<<"$routing_decision" >/dev/null
```

Expected: The selector returns the first eligible default profile without reserving capacity or launching a worker.

- [ ] **Step 6: Run the focused routing regression suite after activation**

Run:

```bash
cd /home/yaro/work/firstmate
tests/fm-route.test.sh
```

Expected: The routing suite exits zero with all behavioral checks passing.

- [ ] **Step 7: Roll back only if a post-change check fails**

Run this step only after a failure in Steps 4 through 6:

```bash
cd /home/yaro/work/firstmate
git apply <<'PATCH'
diff --git a/config/crew-dispatch.json b/config/crew-dispatch.json
--- a/config/crew-dispatch.json
+++ b/config/crew-dispatch.json
@@ -1,7 +1,7 @@
 {
   "schemaVersion": 2,
   "routing": {
-    "mode": "automatic",
+    "mode": "canary",
     "limits": {
       "canary": 3,
       "automatic": 6,
PATCH
test "$(jq -r '.routing.mode' config/crew-dispatch.json)" = canary
bin/fm-route.sh status | jq -e '.mode == "canary"' >/dev/null
```

Expected: The router returns to canary mode while all profiles, limits, circuit state, and outcome history remain intact.

- [ ] **Step 8: Record the private activation outcome**

No code commit is created because the active policy is intentionally gitignored and private to this FirstMate home.
Record the final mode, limits, circuit-breaker values, dry-run result, and test result in the operator handoff.
