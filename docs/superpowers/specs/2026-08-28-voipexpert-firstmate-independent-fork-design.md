# VoIP Expert FirstMate Independent Fork Design

**Date:** 2026-08-28
**Status:** Approved design

## Objective

Make `voipexpert/firstmate` the authoritative FirstMate repository used by VoIP Expert. The deployment must not depend on upstream accepting changes. The original `kunchenguid/firstmate` repository remains available only as a read-only source of selectively reviewed improvements.

## Goals

- Run the completed subscription-first automatic-dispatch work from a repository controlled by VoIP Expert.
- Keep one clear production branch: `voipexpert/firstmate:main`.
- Preserve the existing private FirstMate home, fleet state, configuration, and credentials during code upgrades.
- Require the complete verification gate before merging or deploying.
- Permit upstream improvements only through explicit, isolated review work.
- Provide a simple, auditable rollback to the last known-good internal release.

## Non-goals

- Maintaining a continuously synchronized mirror of upstream `main`.
- Automatically merging upstream changes.
- Depending on approval or CI policy in `kunchenguid/firstmate`.
- Moving private runtime state into Git.
- Enabling automatic production routing as part of the repository migration itself.

## Repository Topology

The canonical development clone on the coding server will use these remotes:

- `origin`: `https://github.com/voipexpert/firstmate.git` — writable, authoritative.
- `upstream`: `https://github.com/kunchenguid/firstmate.git` — read-only reference.

The current feature branch, `feat/firstmate-optimization-design`, remains the source of the tested optimization work. It will be integrated into the fork's `main` after reconciling the 42 upstream commits that landed after the original fork point.

The existing upstream PR may remain open during integration for review evidence. It is not a delivery dependency and may be closed after the internal release is verified.

## Integration Strategy

Create `integration/voipexpert-v1.0.0` from the current authoritative fork `main`, merge the optimized feature branch into it, and resolve conflicts deliberately. Conflict resolution must preserve the tested automatic-dispatch safety architecture while retaining compatible upstream fixes.

Do not rebase or force-push the completed feature branch. This preserves its reviewed commit history and existing PR evidence. After the integration branch passes all verification, merge it into `voipexpert/firstmate:main` with an ordinary merge commit and push it to the fork.

No merge occurs without the captain's explicit approval at the merge gate.

## Verification Gates

The integration branch must pass:

1. The repository's full portable test suite.
2. The isolated automatic-dispatch verification suite.
3. The host-sensitive routing tests on the coding server.
4. Shell syntax/static validation required by the repository.
5. A clean worktree and review of the final diff against both the feature branch and the fork's prior `main`.
6. A smoke test showing FirstMate can start with the existing private home without changing production routing policy.

Any failure stops integration. Fixes are committed to the integration branch and the complete affected gate is rerun.

## Release and Deployment

After the fork `main` is green, create an annotated internal release tag using the `voipexpert-v<major>.<minor>.<patch>` convention. The first optimized release is expected to be `voipexpert-v1.0.0` unless an existing tag conflicts.

The canonical runtime checkout is `/home/yaro/work/firstmate` on the coding server. Before changing its branch or remotes, record its current commit, tracked divergence, worktrees, and complete untracked-file inventory. If any existing material would be overwritten or displaced, stop and move the deployment to a new canonical checkout rather than stashing, deleting, or overwriting that material.

Deploy by updating the safe canonical runtime checkout from `voipexpert/firstmate:main` using fast-forward-only Git operations. The deployment must preserve every existing untracked operational artifact, the private `FM_HOME` directories, and all gitignored `config/`, `data/`, and `state/` content. Installation or migration commands are run only when required by a reviewed repository change.

Restart only the FirstMate runtime components whose code or startup contract changed. Verify service/session health immediately after restart. Automatic production routing remains off until its separate staged rollout gates are approved and completed.

## Upstream Intake

Upstream updates are opt-in:

1. Fetch `upstream` without merging it into production.
2. Create a dedicated `upstream-intake/<date-or-topic>` branch from the current VoIP Expert `main`.
3. Cherry-pick or manually port only selected changes.
4. Run the same verification gates used for internal changes.
5. Merge only after explicit review and approval.

Bulk merging upstream `main`, automatic synchronization, and force updates are prohibited. Upstream changes that conflict with VoIP Expert's dispatch architecture are skipped or adapted locally.

## Rollback

Before each deployment, record the currently deployed commit and retain its internal release tag. If startup, supervision, routing, or test smoke checks fail, restore the checkout to the last known-good tagged release and restart only the affected runtime components. Private state is preserved; rollback must not delete or rewrite `FM_HOME` data.

## Security and Secrets

Only shared code and documentation are committed. API keys, subscription credentials, account maps, routing policy, circuit state, and fleet runtime records remain in gitignored private paths with their existing permissions. Repository remotes use the authenticated VoIP Expert GitHub identity. No credentials are copied into the fork or release artifacts.

## Success Criteria

- `voipexpert/firstmate:main` contains the optimized implementation and is the configured writable canonical remote.
- The complete integration verification gate passes at the exact merged commit.
- An internal release tag identifies the deployed version.
- The coding server runs that exact commit while preserving its existing private FirstMate home.
- The deployment does not depend on upstream PR acceptance.
- Upstream remains available only through the explicit intake workflow above.
