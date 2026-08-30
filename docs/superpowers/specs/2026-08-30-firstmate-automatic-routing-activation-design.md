# FirstMate Automatic Routing Activation Design

**Status:** Implemented and verified

**Date:** 2026-08-30

## Purpose

Activate the already implemented and successfully canary-tested subscription router for normal FirstMate work.
The activation must increase throughput without changing task authority, model eligibility, account allocation, review requirements, or destructive-action safeguards.

## Current Evidence

The deployed FirstMate revision is `73a5365743bb4fd43d97f3210ae5ca52c91e5e46`.
The unattended Codex canary completed successfully and produced the expected marker without dialogs or duplicate bypass flags.
The live routing status reports no active workers and no open circuit breakers.
The live private policy currently selects `canary` mode.

## Approved Configuration

Activation changes only `routing.mode` in the private `config/crew-dispatch.json` policy from `canary` to `automatic`.
The following existing controls remain unchanged:

- Full automatic concurrency cap is six workers.
- Per-lane concurrency cap is two workers.
- Per-account concurrency cap is two workers.
- The burst ceiling is eight workers and remains reserved for an explicit burst decision.
- A lane circuit opens after three failures in a fifteen-minute window.
- An open lane remains in cooldown for thirty minutes.
- A proven transient launch or transport failure receives at most one bounded retry.

No routing profile, task-classification rule, provider priority, model alias, credential, authentication store, or task safety rule changes in this activation.

## Runtime Behavior

FirstMate may automatically select an eligible healthy profile for already-authorized work.
The router respects total, lane, and account capacity before launching a worker.
An unavailable model, exhausted subscription, authentication failure, or open circuit moves selection to the next qualified profile.
Automatic routing chooses the worker and model but never expands what the captain authorized.
Existing confirmation requirements remain in force for destructive, irreversible, security-sensitive, production, and ambiguous writes.

The mode change is applied while no routed workers are active.
This avoids changing policy beneath an in-flight routing decision.

## Failure Handling

Invalid policy JSON or a rejected routing status prevents activation from being accepted.
Circuit breakers contain repeated failures on unhealthy lanes without disabling healthy alternatives.
An uncertain partial write is not retried automatically.
Any safety or authority ambiguity stops the affected task for captain review.

Operational rollback changes only `routing.mode` back to `canary`.
Rollback preserves the same profiles, limits, outcome history, and circuit state.

## Verification

Activation is complete only when all of the following evidence is fresh:

1. The private policy parses as valid JSON.
2. The routing status reports `automatic` mode.
3. The status reports an automatic cap of six, a burst cap of eight, and per-lane and per-account caps of two.
4. The status reports the unchanged three-failure, fifteen-minute, thirty-minute circuit-breaker policy.
5. Focused routing tests pass against the deployed FirstMate revision.
6. A routing selection dry run identifies an eligible automatic profile without launching paid or destructive work.
7. FirstMate is restarted or reloaded only if the deployed runtime does not read the private policy on each routing decision.

If any verification fails, the mode returns to `canary` and the failure is reported with its concrete evidence.

## Deployment Boundary

The approved production change is the private policy update on the coding server.
This design record and its implementation plan are tracked for repeatability and auditability.
No shared runtime code change is required unless verification reveals that the deployed router cannot honor its documented automatic mode.

## Non-Goals

This activation does not:

- Enable the burst ceiling by default.
- Increase any provider or account concurrency limit.
- Add models, providers, accounts, or credentials.
- Modify FirstMate's merge, production, security, or destructive-action authority.
- Launch a large project solely to test routing.
- Replace the existing routing design or implementation.

## Success Criteria

FirstMate reports automatic mode with the approved limits and unchanged circuit breakers.
It can select healthy subscription-backed capacity for a small task without manual profile selection.
The captain retains the same approval boundaries while routine authorized work routes automatically.
