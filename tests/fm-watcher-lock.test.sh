#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

# An arm only reports its typed failure after wait_for_healthy_successor has
# spent the whole confirmation budget, so cases that wait for that failure must
# outlast the largest production default (30s on MSYS, 10s elsewhere - see
# ARM_CONFIRM_DEFAULT in bin/fm-watch-arm.sh). This is a ceiling spent only when
# an arm genuinely fails to exit; a passing case returns as soon as it does.
ARM_FAIL_EXIT_POLLS=400

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

drain_and_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

test_pid_matches_identity() {  # <pid> <expected-identity>
  local pid=$1 expected=$2 current
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$expected" ] || return 1
  is_live_non_zombie "$pid" || return 1
  current=$(fm_test_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

cleanup_identity_bound_arm_pair() {  # <arm-pid> <arm-id> <watcher-pid> <watcher-id> <reap-arm>
  local arm_pid=$1 arm_identity=$2 watcher_pid=$3 watcher_identity=$4 reap_arm=$5 i
  if test_pid_matches_identity "$watcher_pid" "$watcher_identity"; then
    kill -CONT "$watcher_pid" 2>/dev/null || true
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if test_pid_matches_identity "$arm_pid" "$arm_identity"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ]; do
    test_pid_matches_identity "$arm_pid" "$arm_identity" \
      || test_pid_matches_identity "$watcher_pid" "$watcher_identity" \
      || break
    sleep 0.1
    i=$((i + 1))
  done
  if test_pid_matches_identity "$watcher_pid" "$watcher_identity"; then
    kill -CONT "$watcher_pid" 2>/dev/null || true
    kill -KILL "$watcher_pid" 2>/dev/null || true
  fi
  if test_pid_matches_identity "$arm_pid" "$arm_identity"; then
    kill -KILL "$arm_pid" 2>/dev/null || true
  fi
  if [ "$reap_arm" = 1 ]; then
    wait "$arm_pid" 2>/dev/null || true
  fi
  i=0
  while [ "$i" -lt 80 ]; do
    test_pid_matches_identity "$arm_pid" "$arm_identity" \
      || test_pid_matches_identity "$watcher_pid" "$watcher_identity" \
      || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

cleanup_arm_hup_probe() {
  local cleanup_rc=0
  trap - EXIT INT TERM
  [ "${arm_cleanup_active:-0}" = 1 ] || return 0
  if test_pid_matches_identity "${fresh_sleep_pid:-}" "${fresh_sleep_identity:-}"; then
    kill -TERM "$fresh_sleep_pid" 2>/dev/null || true
  fi
  cleanup_identity_bound_arm_pair \
    "${armpid:-}" "${arm_identity:-}" "${lock_pid:-}" "${lock_identity:-}" 1 \
    || cleanup_rc=$?
  if test_pid_matches_identity "${sentinel_pid:-}" "${sentinel_identity:-}"; then
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  if [ -n "${evidence_dir:-}" ]; then
    printf '%s\n' "$cleanup_rc" > "$evidence_dir/cleanup.rc"
  fi
  if [ -n "${dir:-}" ] && [ -n "${TMP_ROOT:-}" ] \
    && [ "${dir#"$TMP_ROOT"/}" != "$dir" ]; then
    rm -rf -- "$dir"
  fi
  arm_cleanup_active=0
  return "$cleanup_rc"
}

cleanup_arm_preconfirmation_probe() {
  local cleanup_rc=0 current_identity
  trap - EXIT INT TERM
  [ "${arm_cleanup_active:-0}" = 1 ] || return 0
  if [ -z "${child_pid:-}" ] && [ -n "${ready:-}" ]; then
    child_pid=$(sed -n 's/^child_pid=//p' "$ready" 2>/dev/null || true)
  fi
  current_identity=$(fm_test_pid_identity "${child_pid:-}" 2>/dev/null || true)
  [ -z "$current_identity" ] || child_identity=$current_identity
  cleanup_identity_bound_arm_pair \
    "${armpid:-}" "${arm_identity:-}" "${child_pid:-}" "${child_identity:-}" 1 \
    || cleanup_rc=$?
  if test_pid_matches_identity "${sentinel_pid:-}" "${sentinel_identity:-}"; then
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  if [ -n "${dir:-}" ] && [ -n "${TMP_ROOT:-}" ] \
    && [ "${dir#"$TMP_ROOT"/}" != "$dir" ]; then
    rm -rf -- "$dir"
  fi
  arm_cleanup_active=0
  return "$cleanup_rc"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mark_pr_check_migration_complete "$state"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard banner missing neutral automatic-recovery guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard did not order neutral automatic recovery after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) live watcher plus fresh beacon, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") || fail "could not identify fresh guard watcher"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when live and fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" \
    && fail "restart did not surface recovery after replacing a reused-pid lock"
  wait "$pid" 2>/dev/null || true
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "restart replaced reused-pid lock without surfacing recovery: $(cat "$out")"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart preserves recovery without signaling a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer_ready peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  mark_pr_check_migration_complete "$state"
  node -e 'const fs = require("node:fs"); process.on("SIGTERM", () => {}); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" &
  peer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$peer_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$peer_ready" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "TERM-resistant peer did not become ready"
  fi
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  # The arm's confirmation budget bounds a REAL child startup (fork, exec, lock
  # acquisition, beacon publication), so this case holds the arm to production's
  # own budget rather than a shrunken fixture one: a one-second budget turned
  # ordinary CPU contention into an honest "FAILED - no live watcher with a fresh
  # beacon" and broke this case's premise under full-suite load (issue #2844).
  # It stays at the production default rather than something roomier because the
  # same budget bounds the successor wait this case deliberately spends below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      if [ "$row" = dead-pid ]; then
        is_live_non_zombie "$armpid" || break
      else
        grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      fi
      sleep 0.1; i=$((i + 1))
    done
    if [ "$row" = dead-pid ]; then
      is_live_non_zombie "$armpid" \
        && fail "arm did not surface recovery after reclaiming a dead-pid lock"
      wait "$armpid" 2>/dev/null || true
      grep -F 'check: rearm-resurface' "$armout" >/dev/null \
        || fail "arm reclaimed dead-pid lock without surfacing recovery: $(cat "$armout")"
      continue
    fi
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts cleanly and resurfaces recovery after a dead-pid lock"
}

test_arm_hup_cleans_child_and_temp_output() (
  local dir state fakebin armout poll_ready real_ps real_sleep stale_generation delayed_generation fresh_generation
  local evidence_dir arm_identity lock_identity i armpid lock_pid status arm_exit_polls stopped_mode
  local watcher_parent watcher_state stopped_generation fresh_sleep_pid fresh_sleep_identity fresh_sleep_parent
  local sentinel_pid sentinel_identity lifecycle_row poll_seconds arm_proc_root portable_ps_log
  local arm_cleanup_active
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  poll_ready="$dir/poll-sleep.ready"
  real_ps=$(command -v ps)
  real_sleep=$(command -v sleep)
  arm_exit_polls=${FM_TEST_ARM_HUP_EXIT_POLLS:-$ARM_FAIL_EXIT_POLLS}
  stopped_mode=${FM_TEST_ARM_HUP_STOPPED_CHILD:-0}
  poll_seconds=10
  [ "$stopped_mode" != 1 ] || poll_seconds=2
  arm_cleanup_active=0
  lock_pid=
  lock_identity=
  fresh_sleep_pid=
  fresh_sleep_identity=
  sentinel_pid=
  sentinel_identity=
  arm_proc_root=/proc
  portable_ps_log="$dir/portable-ps.log"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "${FM_TEST_BLOCKING_SLEEP_SECONDS:-}" ]; then
  ready=${FM_TEST_BLOCKING_SLEEP_READY:?FM_TEST_BLOCKING_SLEEP_READY unset}
  tmp="$ready.$$"
  printf '%s\n' "$$" > "$tmp"
  mv -f "$tmp" "$ready"
  if [ "${FM_TEST_PARENT_RUNNING_SLEEP:-0}" = 1 ]; then
    required=${FM_TEST_PARENT_RUNNING_SLEEP_TICKS:-15}
    remaining=$required
    while [ "$remaining" -gt 0 ]; do
      parent_state=$(ps -p "$PPID" -o stat= 2>/dev/null | tr -d '[:space:]')
      case "$parent_state" in
        T*)
          stopped_tmp="$ready.stopped.$$"
          printf '%s\n' "$$" > "$stopped_tmp"
          mv -f "$stopped_tmp" "$ready.stopped"
          remaining=$required
          ;;
        *) remaining=$((remaining - 1)) ;;
      esac
      "${FM_TEST_REAL_SLEEP:?FM_TEST_REAL_SLEEP unset}" 0.1
    done
    exit 0
  fi
fi
exec "${FM_TEST_REAL_SLEEP:?FM_TEST_REAL_SLEEP unset}" "$@"
SH
  chmod +x "$fakebin/sleep"
  if [ "${FM_TEST_ARM_PORTABLE_PS:-0}" = 1 ]; then
    arm_proc_root="$dir/no-proc"
    cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$#:${3-}:${4-}:${5-}:${6-}:${7-}:${8-}" in
  6:-o:lstart=:-o:command=::)
    printf 'identity LC_ALL=%s\n' "${LC_ALL-<unset>}" >> "${FM_TEST_PORTABLE_PS_LOG:?FM_TEST_PORTABLE_PS_LOG unset}"
    ;;
  8:-o:lstart=:-o:stat=:-o:ppid=)
    printf 'snapshot LC_ALL=%s\n' "${LC_ALL-<unset>}" >> "${FM_TEST_PORTABLE_PS_LOG:?FM_TEST_PORTABLE_PS_LOG unset}"
    ;;
  *)
    printf 'unsupported %s\n' "$*" >> "${FM_TEST_PORTABLE_PS_LOG:?FM_TEST_PORTABLE_PS_LOG unset}"
    exit 64
    ;;
esac
exec "${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" "$@"
SH
    chmod +x "$fakebin/ps"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_PROC_ROOT_OVERRIDE="$arm_proc_root" \
    FM_POLL="$poll_seconds" FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_BLOCKING_SLEEP_SECONDS="$poll_seconds" FM_TEST_BLOCKING_SLEEP_READY="$poll_ready" \
    FM_TEST_PARENT_RUNNING_SLEEP="$stopped_mode" FM_TEST_PARENT_RUNNING_SLEEP_TICKS=15 \
    FM_TEST_REAL_PS="$real_ps" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_TEST_PORTABLE_PS_LOG="$portable_ps_log" "$WATCH_ARM" > "$armout" &
  armpid=$!
  arm_identity=$(fm_test_pid_identity "$armpid" 2>/dev/null || true)
  if [ -z "$arm_identity" ]; then
    kill -TERM "$armpid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "could not bind cleanup to the started arm identity"
  fi
  arm_cleanup_active=1
  trap 'cleanup_arm_hup_probe' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  lock_identity=$(fm_test_pid_identity "$lock_pid" 2>/dev/null || true)
  [ -n "$lock_identity" ] || fail "could not bind cleanup to the owned watcher identity"
  evidence_dir=${FM_TEST_ARM_HUP_CLEANUP_EVIDENCE:-}
  if [ -n "$evidence_dir" ]; then
    mkdir -p "$evidence_dir"
    printf '%s\n' "$armpid" > "$evidence_dir/arm.pid"
    printf '%s\n' "$arm_identity" > "$evidence_dir/arm.identity"
    printf '%s\n' "$lock_pid" > "$evidence_dir/watcher.pid"
    printf '%s\n' "$lock_identity" > "$evidence_dir/watcher.identity"
    printf '%s\n' "$dir" > "$evidence_dir/fixture-dir"
  fi
  i=0
  while [ "$i" -lt 80 ] && [ ! -e "$poll_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$poll_ready" ] || fail "watcher did not enter the synchronized foreground poll sleep"
  stale_generation=$(cat "$poll_ready")
  [ -n "$stale_generation" ] || fail "watcher published an empty foreground-sleep generation"
  kill -STOP "$lock_pid" 2>/dev/null || fail "could not pause watcher for delayed readiness counterfactual"
  if [ -n "$evidence_dir" ]; then
    printf '%s\n' watcher-stopped > "$evidence_dir/stage"
  fi
  if [ "${FM_TEST_FORCE_ARM_HUP_TERM:-0}" = 1 ]; then
    bash -c 'kill -TERM "$PPID"'
    fail "forced TERM returned instead of ending the cleanup probe"
  fi
  "$real_sleep" 1 || {
    kill -CONT "$lock_pid" 2>/dev/null || true
    fail "delayed readiness counterfactual could not wait"
  }
  delayed_generation=$(cat "$poll_ready" 2>/dev/null || true)
  if [ "$delayed_generation" != "$stale_generation" ]; then
    kill -CONT "$lock_pid" 2>/dev/null || true
    fail "delayed readiness counterfactual did not retain the pre-start sleep generation"
  fi
  rm -f "$poll_ready"
  kill -CONT "$lock_pid" 2>/dev/null || fail "could not resume watcher for a fresh sleep generation"
  fresh_generation=
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ]; do
    fresh_generation=$(cat "$poll_ready" 2>/dev/null || true)
    [ -n "$fresh_generation" ] && [ "$fresh_generation" != "$stale_generation" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$fresh_generation" ] && [ "$fresh_generation" != "$stale_generation" ] \
    || fail "watcher did not publish a fresh foreground-sleep generation"
  if [ "$stopped_mode" = 1 ]; then
    watcher_parent=$(ps -p "$lock_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    [ "$watcher_parent" = "$armpid" ] \
      || fail "identity-bound watcher was not the arm's direct child (parent '$watcher_parent', arm '$armpid')"
    fresh_sleep_pid=$fresh_generation
    fresh_sleep_identity=$(fm_test_pid_identity "$fresh_sleep_pid" 2>/dev/null || true)
    [ -n "$fresh_sleep_identity" ] || fail "could not bind the active watcher sleep identity"
    fresh_sleep_parent=$(ps -p "$fresh_sleep_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    [ "$fresh_sleep_parent" = "$lock_pid" ] \
      || fail "fresh foreground sleep was not owned by the exact watcher"
    "$real_sleep" 60 &
    sentinel_pid=$!
    sentinel_identity=$(fm_test_pid_identity "$sentinel_pid" 2>/dev/null || true)
    [ -n "$sentinel_identity" ] || fail "could not bind unrelated sentinel identity"
    rm -f "$poll_ready.stopped"
    kill -STOP "$lock_pid" 2>/dev/null || fail "could not stop exact owned watcher before HUP"
    i=0
    while [ "$i" -lt 20 ]; do
      watcher_state=$(ps -p "$lock_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
      stopped_generation=$(cat "$poll_ready.stopped" 2>/dev/null || true)
      case "$watcher_state:$stopped_generation" in T*:"$fresh_sleep_pid") break ;; esac
      sleep 0.1
      i=$((i + 1))
    done
    case "$watcher_state:$stopped_generation" in
      T*:"$fresh_sleep_pid") ;;
      *) fail "exact watcher and foreground command did not synchronize in the stopped state before HUP" ;;
    esac
  fi
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  # The arm waits for owned watcher cleanup, and Bash may defer the watcher's
  # TERM trap until its foreground poll command returns. Use the shared ceiling
  # that already covers the largest production confirmation budget.
  wait_for_exit "$armpid" "$arm_exit_polls"
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  if [ "$stopped_mode" = 1 ]; then
    test_pid_matches_identity "$sentinel_pid" "$sentinel_identity" \
      || fail "bounded arm shutdown signalled an unrelated process"
    ! test_pid_matches_identity "$fresh_sleep_pid" "$fresh_sleep_identity" \
      || fail "bounded arm shutdown left the watcher's foreground command running"
    lifecycle_row=$(tail -1 "$state/.watch-cycle-exits.log" 2>/dev/null || true)
    case "$lifecycle_row" in
      "arm_pid=$armpid"$'\t'"watcher_pid=$lock_pid"$'\t'*$'\t'"exit_code=129"$'\t'"signal=HUP"$'\t'"reason=arm-interrupted"$'\t'*) ;;
      *) fail "bounded stopped-watcher shutdown did not preserve the HUP lifecycle row: $lifecycle_row" ;;
    esac
    [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
      || fail "graceful stopped-watcher shutdown left stale lock evidence"
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
    sentinel_pid=
    sentinel_identity=
    fresh_sleep_pid=
    fresh_sleep_identity=
  fi
  arm_cleanup_active=0
  trap - EXIT
  if [ "${FM_TEST_ARM_PORTABLE_PS:-0}" = 1 ]; then
    grep -q '^identity LC_ALL=C$' "$portable_ps_log" \
      || fail "portable watcher path did not read full identity through locale-pinned ps"
    grep -q '^snapshot LC_ALL=C$' "$portable_ps_log" \
      || fail "portable watcher path did not read lifetime, state, and PPID through one locale-pinned ps snapshot"
    ! grep -q '^unsupported ' "$portable_ps_log" \
      || fail "portable watcher path used an unsupported ps query"
    pass "no-/proc watcher cleanup uses the macOS-compatible ps snapshot"
    exit 0
  fi
  pass "arm cleans child watcher and temp output on HUP"
)

test_arm_portable_ps_snapshot_cleans_child() {
  local log rc=0
  log="$TMP_ROOT/arm-portable-ps.log"
  FM_TEST_ARM_PORTABLE_PS=1 bash "$0" > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$log" >&2
    fail "no-/proc portable ps probe exited $rc"
  fi
  grep -F 'ok - no-/proc watcher cleanup uses the macOS-compatible ps snapshot' "$log" >/dev/null \
    || fail "no-/proc portable ps probe did not complete its behavior contract"
  pass "no-/proc watcher cleanup uses the macOS-compatible ps snapshot"
}

test_arm_preconfirmation_signal_reaps_exact_spawned_child() (
  local dir state fakebin armout armerr ready release claim exec_ready exec_release stable_ready
  local production_ps_log fixture_ps_log proc_stat_log
  local real_bash real_cat real_od real_ps real_sleep launch_cmdline_hex stable_identity stable_cmdline_hex
  local armpid arm_identity child_pid child_parent child_identity od_pid status i
  local child_survived=0 od_survived=0 sentinel_pid sentinel_identity sentinel_untouched=0
  local lifecycle_row arm_cleanup_active startup_signal expected_status
  local -a arm_command
  dir=$(make_case arm-preconfirmation-hup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armerr="$dir/arm.err"
  ready="$dir/preconfirmation.ready"
  release="$dir/preconfirmation.release"
  claim="$dir/preconfirmation.claim"
  exec_ready="$dir/watcher-pre-exec.ready"
  exec_release="$dir/watcher-pre-exec.release"
  stable_ready="$dir/watcher-post-exec.ready"
  production_ps_log="$dir/cygwin-production-ps.log"
  fixture_ps_log="$dir/cygwin-fixture-ps.log"
  proc_stat_log="$dir/proc-stat.log"
  real_bash=$(command -v bash)
  real_cat=$(command -v cat)
  real_od=$(command -v od)
  real_ps=$(command -v ps)
  real_sleep=$(command -v sleep)
  mark_pr_check_migration_complete "$state"
  arm_cleanup_active=0
  child_pid=
  child_identity=
  sentinel_pid=
  sentinel_identity=
  startup_signal=${FM_TEST_ARM_PRECONFIRMATION_SIGNAL:-HUP}
  case "$startup_signal" in
    HUP) expected_status=129 ;;
    TERM) expected_status=143 ;;
    INT) expected_status=130 ;;
    *) fail "invalid pre-confirmation signal '$startup_signal'" ;;
  esac

  # Keep the exact watcher PID in a pre-exec shell until the parent has sampled
  # that mutable argv identity. The test later releases this wrapper and waits
  # for the real watcher lock before allowing the pending HUP trap to run, which
  # proves the startup ownership binding survives the legitimate exec change.
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
set -u
if [ "${1:-}" = "${FM_TEST_WATCH_PATH:?FM_TEST_WATCH_PATH unset}" ]; then
  tmp="${FM_TEST_WATCH_EXEC_READY:?FM_TEST_WATCH_EXEC_READY unset}.$$"
  printf '%s\n' "$$" > "$tmp"
  mv -f "$tmp" "$FM_TEST_WATCH_EXEC_READY"
  while [ ! -e "${FM_TEST_WATCH_EXEC_RELEASE:?FM_TEST_WATCH_EXEC_RELEASE unset}" ]; do
    "${FM_TEST_REAL_SLEEP:?FM_TEST_REAL_SLEEP unset}" 0.02
  done
fi
exec "${FM_TEST_REAL_BASH:?FM_TEST_REAL_BASH unset}" "$@"
SH
  chmod +x "$fakebin/bash"

  if [ "${FM_TEST_ARM_CYGWIN_PS:-0}" = 1 ]; then
    # Cygwin ps accepts -p but not the portable -o format. Keep test
    # orchestration on the captured real ps while production sees this shim.
    cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = -o ]; then
    printf '%s\n' "$*" >> "${FM_TEST_CYGWIN_PS_LOG:?FM_TEST_CYGWIN_PS_LOG unset}"
    exit 64
  fi
done
exec "${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" "$@"
SH
    chmod +x "$fakebin/ps"

    # Preserve real process fields while forcing a comm value with spaces and
    # a closing parenthesis. The production parser must split after the final
    # ')' instead of tokenizing the comm field.
    cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  /proc/[0-9]*/stat)
    target=${last%/stat}
    target=${target##*/}
    line=$("${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" "$last") || exit 1
    printf '%s\n' "$target" >> "${FM_TEST_PROC_STAT_LOG:?FM_TEST_PROC_STAT_LOG unset}"
    printf '%s (watcher ) with spaces)%s\n' "$target" "${line##*)}"
    exit 0
    ;;
esac
exec "${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" "$@"
SH
    chmod +x "$fakebin/cat"

    if FM_TEST_CYGWIN_PS_LOG="$production_ps_log" FM_TEST_REAL_PS="$real_ps" \
      "$fakebin/ps" -p "$$" -o ppid= >/dev/null 2>&1; then
      fail "Cygwin-like ps fixture unexpectedly accepted -o"
    fi
    : > "$production_ps_log"
  fi

  # Hold only the arm parent's identity read after it has emitted the real
  # cmdline bytes. HUP is therefore pending after the watcher spawn and $!
  # assignment, but before cycle_begin can publish the child's identity. The
  # watcher's own identity read has the target as its caller's parent and is not
  # delayed, so this is an exact startup-boundary synchronization rather than a
  # timing guess.
  cat > "$fakebin/od" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  /proc/[0-9]*/cmdline)
    target=${last%/cmdline}
    target=${target##*/}
    caller_parent=$("${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" -p "$PPID" -o ppid= 2>/dev/null | tr -d '[:space:]')
    arm_pid=$("$FM_TEST_REAL_PS" -p "$caller_parent" -o ppid= 2>/dev/null | tr -d '[:space:]')
    if [ "$arm_pid" != "$target" ] \
      && ( set -C; : > "${FM_TEST_PRECONFIRM_CLAIM:?FM_TEST_PRECONFIRM_CLAIM unset}" ) 2>/dev/null; then
      captured=$("${FM_TEST_REAL_OD:?FM_TEST_REAL_OD unset}" "$@" | tr -d '[:space:]')
      printf '%s\n' "$captured"
      tmp="${FM_TEST_PRECONFIRM_READY:?FM_TEST_PRECONFIRM_READY unset}.$$"
      {
        printf 'arm_pid=%s\n' "$arm_pid"
        printf 'child_pid=%s\n' "$target"
        printf 'od_pid=%s\n' "$$"
        printf 'launch_cmdline_hex=%s\n' "$captured"
      } > "$tmp"
      mv -f "$tmp" "$FM_TEST_PRECONFIRM_READY"
      if [ -n "${FM_TEST_PRECONFIRM_SELF_SIGNAL:-}" ]; then
        kill -"$FM_TEST_PRECONFIRM_SELF_SIGNAL" "$arm_pid"
        : > "${FM_TEST_WATCH_EXEC_RELEASE:?FM_TEST_WATCH_EXEC_RELEASE unset}"
        i=0
        while [ "$i" -lt 400 ]; do
          lock_pid=$("${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" \
            "${FM_TEST_STATE:?FM_TEST_STATE unset}/.watch.lock/pid" 2>/dev/null || true)
          [ "$lock_pid" = "$target" ] && [ -e "$FM_TEST_STATE/.last-watcher-beat" ] && break
          "${FM_TEST_REAL_SLEEP:?FM_TEST_REAL_SLEEP unset}" 0.02
          i=$((i + 1))
        done
        [ "$lock_pid" = "$target" ] && [ -e "$FM_TEST_STATE/.last-watcher-beat" ] || exit 91
        stable=$("$FM_TEST_REAL_OD" "$@" | tr -d '[:space:]')
        tmp="${FM_TEST_STABLE_READY:?FM_TEST_STABLE_READY unset}.$$"
        printf '%s\n' "$stable" > "$tmp"
        mv -f "$tmp" "$FM_TEST_STABLE_READY"
        exit 0
      fi
      while [ ! -e "${FM_TEST_PRECONFIRM_RELEASE:?FM_TEST_PRECONFIRM_RELEASE unset}" ]; do
        "${FM_TEST_REAL_SLEEP:?FM_TEST_REAL_SLEEP unset}" 0.02
      done
      exit 0
    fi
    ;;
esac
exec "${FM_TEST_REAL_OD:?FM_TEST_REAL_OD unset}" "$@"
SH
  chmod +x "$fakebin/od"

  arm_cleanup_active=1
  trap 'cleanup_arm_preconfirmation_probe' EXIT

  "$real_sleep" 60 &
  sentinel_pid=$!
  sentinel_identity=$(fm_test_pid_identity "$sentinel_pid" 2>/dev/null || true)
  [ -n "$sentinel_identity" ] || fail "could not bind pre-confirmation unrelated sentinel"

  arm_command=(
    env "PATH=$fakebin:$PATH" "FM_HOME=$dir" "FM_STATE_OVERRIDE=$state"
    "FM_POLL=30" "FM_SIGNAL_GRACE=1" "FM_CHECK_INTERVAL=999999" "FM_HEARTBEAT=999999"
    "FM_TEST_REAL_BASH=$real_bash" "FM_TEST_REAL_CAT=$real_cat" "FM_TEST_REAL_OD=$real_od"
    "FM_TEST_REAL_PS=$real_ps" "FM_TEST_REAL_SLEEP=$real_sleep" "FM_TEST_STATE=$state"
    "FM_TEST_CYGWIN_PS_LOG=$production_ps_log" "FM_TEST_PROC_STAT_LOG=$proc_stat_log"
    "FM_TEST_WATCH_PATH=$WATCH" "FM_TEST_WATCH_EXEC_READY=$exec_ready"
    "FM_TEST_WATCH_EXEC_RELEASE=$exec_release" "FM_TEST_PRECONFIRM_CLAIM=$claim"
    "FM_TEST_PRECONFIRM_READY=$ready" "FM_TEST_PRECONFIRM_RELEASE=$release"
    "FM_TEST_STABLE_READY=$stable_ready" "$real_bash" "$WATCH_ARM"
  )
  if [ "$startup_signal" = INT ]; then
    FM_TEST_PRECONFIRM_SELF_SIGNAL=INT "${arm_command[@]}" > "$armout" 2> "$armerr"
    status=$?
    armpid=$(sed -n 's/^arm_pid=//p' "$ready" 2>/dev/null || true)
    arm_identity=
  else
    "${arm_command[@]}" > "$armout" 2> "$armerr" &
    armpid=$!
    arm_identity=$(fm_test_pid_identity "$armpid" 2>/dev/null || true)
    [ -n "$arm_identity" ] || fail "could not bind pre-confirmation arm identity"
  fi

  i=0
  while [ "$i" -lt 160 ] && [ ! -s "$ready" ]; do
    "$real_sleep" 0.05
    i=$((i + 1))
  done
  [ -s "$ready" ] || fail "arm did not enter the synchronized pre-confirmation identity window"
  [ -n "$armpid" ] || armpid=$(sed -n 's/^arm_pid=//p' "$ready")
  child_pid=$(sed -n 's/^child_pid=//p' "$ready")
  od_pid=$(sed -n 's/^od_pid=//p' "$ready")
  launch_cmdline_hex=$(sed -n 's/^launch_cmdline_hex=//p' "$ready")
  case "$child_pid:$od_pid" in
    *[!0-9:]*|:*) fail "pre-confirmation synchronization published invalid process identities" ;;
  esac
  [ -n "$launch_cmdline_hex" ] \
    || fail "pre-confirmation synchronization did not capture the launch argv identity"
  i=0
  while [ "$i" -lt 160 ] && [ "$(cat "$exec_ready" 2>/dev/null || true)" != "$child_pid" ]; do
    "$real_sleep" 0.05
    i=$((i + 1))
  done
  [ "$(cat "$exec_ready" 2>/dev/null || true)" = "$child_pid" ] \
    || fail "watcher child did not enter the synchronized pre-exec window"
  if [ "$startup_signal" = INT ]; then
    child_parent=$(sed -n 's/^arm_pid=//p' "$ready")
    stable_cmdline_hex=$(cat "$stable_ready" 2>/dev/null || true)
  else
    child_parent=$("$real_ps" -p "$child_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    kill -"$startup_signal" "$armpid" 2>/dev/null \
      || fail "could not interrupt arm with $startup_signal during pre-confirmation"
    : > "$exec_release"
    i=0
    while [ "$i" -lt 160 ]; do
      [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child_pid" ] \
        && [ -e "$state/.last-watcher-beat" ] && break
      "$real_sleep" 0.05
      i=$((i + 1))
    done
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child_pid" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      || fail "watcher did not complete the synchronized exec transition"
    stable_identity=$(fm_test_pid_identity "$child_pid" 2>/dev/null || true)
    stable_cmdline_hex=${stable_identity#*cmdline-hex=}
    [ -n "$stable_identity" ] && [ "$stable_cmdline_hex" != "$stable_identity" ] \
      || fail "could not bind the post-exec watcher identity"
    : > "$release"
    wait_for_exit "$armpid" 160
    status=$?
  fi
  [ "$child_parent" = "$armpid" ] \
    || fail "synchronized watcher was not the arm's exact direct child"
  [ -n "$stable_cmdline_hex" ] \
    || fail "could not bind the post-exec watcher identity"
  [ "$stable_cmdline_hex" != "$launch_cmdline_hex" ] \
    || fail "pre-confirmation fixture did not force an argv identity transition"

  is_live_non_zombie "$child_pid" && child_survived=1
  is_live_non_zombie "$od_pid" && od_survived=1
  test_pid_matches_identity "$sentinel_pid" "$sentinel_identity" && sentinel_untouched=1
  lifecycle_row=$(tail -1 "$state/.watch-cycle-exits.log" 2>/dev/null || true)
  if [ "${FM_TEST_ARM_CYGWIN_GONE_IDENTITY:-0}" = 1 ]; then
    ! is_live_non_zombie "$child_pid" \
      || fail "gone-identity fixture reached cleanup before the watcher disappeared"
  fi
  if [ "$child_survived" -eq 0 ]; then
    child_identity=${stable_identity:-}
  elif [ -n "${stable_identity:-}" ]; then
    child_identity=$stable_identity
  elif [ "${FM_TEST_ARM_CYGWIN_PS:-0}" = 1 ]; then
    child_identity=$(PATH="$fakebin:$PATH" FM_TEST_WATCH_PATH="$WATCH" \
      FM_TEST_REAL_BASH="$real_bash" FM_TEST_CYGWIN_PS_LOG="$fixture_ps_log" \
      FM_TEST_REAL_PS="$real_ps" fm_test_pid_identity "$child_pid" 2>/dev/null || true)
  else
    child_identity=$(fm_test_pid_identity "$child_pid" 2>/dev/null || true)
  fi

  # RED containment remains exact-PID/exact-identity. It runs before assertions
  # so the intentionally failing original implementation cannot leak the child.
  cleanup_identity_bound_arm_pair \
    "$armpid" "$arm_identity" "$child_pid" "$child_identity" 0 \
    || fail "pre-confirmation RED containment could not retire its exact processes"
  if test_pid_matches_identity "$sentinel_pid" "$sentinel_identity"; then
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  sentinel_pid=
  sentinel_identity=
  arm_cleanup_active=0
  trap - EXIT

  [ "$status" -eq "$expected_status" ] \
    || fail "pre-confirmation $startup_signal returned $status instead of $expected_status"
  [ "$child_survived" -eq 0 ] \
    || fail "pre-confirmation $startup_signal forgot the newly spawned watcher child"
  [ "$od_survived" -eq 0 ] \
    || fail "pre-confirmation $startup_signal left its identity-output process running"
  [ "$sentinel_untouched" -eq 1 ] \
    || fail "pre-confirmation $startup_signal signalled an unrelated process"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 \
    || fail "pre-confirmation $startup_signal left temp output behind"
  case "$lifecycle_row" in
    "arm_pid=$armpid"$'\t'"watcher_pid=$child_pid"$'\t'*$'\t'"exit_code=$expected_status"$'\t'"signal=$startup_signal"$'\t'"reason=arm-interrupted"$'\t'*) ;;
    *) fail "pre-confirmation $startup_signal did not retain the exact child lifecycle row: $lifecycle_row" ;;
  esac
  if [ "${FM_TEST_ARM_CYGWIN_PS:-0}" = 1 ]; then
    grep -Fx "$child_pid" "$proc_stat_log" >/dev/null \
      || fail "Cygwin-like /proc fixture did not exercise the child stat parser"
    [ ! -s "$production_ps_log" ] \
      || fail "Cygwin-like production cleanup invoked unsupported ps -o: $(tr '\n' ';' < "$production_ps_log")"
    if [ "${FM_TEST_ARM_CYGWIN_GONE_IDENTITY:-0}" = 1 ]; then
      [ ! -s "$fixture_ps_log" ] \
        || fail "gone-child test cleanup performed an unnecessary identity fallback"
    fi
  fi
  pass "pre-confirmation $startup_signal reaps only the exact newly spawned watcher"
)

test_arm_preconfirmation_signals_reap_exact_spawned_child() {
  local startup_signal log rc
  for startup_signal in HUP TERM INT; do
    log="$TMP_ROOT/arm-preconfirmation-$startup_signal.log"
    rc=0
    FM_TEST_ARM_PRECONFIRMATION_HUP=1 FM_TEST_ARM_PRECONFIRMATION_SIGNAL="$startup_signal" \
      bash "$0" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$log" >&2
      fail "pre-confirmation $startup_signal probe exited $rc"
    fi
    grep -F "ok - pre-confirmation $startup_signal reaps only the exact newly spawned watcher" "$log" >/dev/null \
      || fail "pre-confirmation $startup_signal probe did not complete its behavior contract"
  done
  pass "pre-confirmation HUP, TERM, and INT reap only the exact newly spawned watcher"
}

test_arm_cygwin_ps_preconfirmation_signals_reap_exact_spawned_child() {
  local startup_signal log rc
  for startup_signal in HUP TERM INT; do
    log="$TMP_ROOT/arm-cygwin-preconfirmation-$startup_signal.log"
    rc=0
    FM_TEST_ARM_PRECONFIRMATION_HUP=1 FM_TEST_ARM_PRECONFIRMATION_SIGNAL="$startup_signal" \
      FM_TEST_ARM_CYGWIN_PS=1 bash "$0" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$log" >&2
      fail "Cygwin-like pre-confirmation $startup_signal probe exited $rc"
    fi
    grep -F "ok - pre-confirmation $startup_signal reaps only the exact newly spawned watcher" "$log" >/dev/null \
      || fail "Cygwin-like pre-confirmation $startup_signal probe did not complete its behavior contract"
  done
  pass "Cygwin-like HUP, TERM, and INT reap the exact pre-confirmation watcher without ps -o"
}

test_arm_signal_reaps_child_when_full_identity_is_unavailable() (
  local dir state fakebin armout armerr ready fail_log real_od real_ps real_sleep
  local armpid arm_identity child_pid child_identity child_parent sentinel_pid sentinel_identity
  local status i lifecycle_row arm_cleanup_active child_survived=0 sentinel_untouched=0
  dir=$(make_case arm-identity-unavailable)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armerr="$dir/arm.err"
  ready="$dir/identity-failure.ready"
  fail_log="$dir/identity-failure.log"
  real_od=$(command -v od)
  real_ps=$(command -v ps)
  real_sleep=$(command -v sleep)
  mark_pr_check_migration_complete "$state"
  arm_cleanup_active=0
  child_pid=
  child_identity=
  sentinel_pid=
  sentinel_identity=

  # Reject every full cmdline identity read made by the arm while allowing the
  # exact watcher to identify itself and establish its real lock normally. A
  # target PID in the od process's ancestor chain is a self-read; a sibling
  # target is the arm inspecting its child.
  cat > "$fakebin/od" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  /proc/[0-9]*/cmdline)
    target=${last%/cmdline}
    target=${target##*/}
    ancestor=$PPID
    self_read=0
    while [ "$ancestor" -gt 1 ]; do
      if [ "$ancestor" = "$target" ]; then
        self_read=1
        break
      fi
      ancestor=$("${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" -p "$ancestor" -o ppid= 2>/dev/null | tr -d '[:space:]')
      case "$ancestor" in ''|*[!0-9]*) break ;; esac
    done
    if [ "$self_read" -eq 0 ]; then
      tmp="${FM_TEST_IDENTITY_FAILURE_READY:?FM_TEST_IDENTITY_FAILURE_READY unset}.$$"
      printf 'child_pid=%s\n' "$target" > "$tmp"
      mv -f "$tmp" "$FM_TEST_IDENTITY_FAILURE_READY"
      printf 'arm-full-identity-failed child_pid=%s\n' "$target" \
        >> "${FM_TEST_IDENTITY_FAILURE_LOG:?FM_TEST_IDENTITY_FAILURE_LOG unset}"
      exit 1
    fi
    ;;
esac
exec "${FM_TEST_REAL_OD:?FM_TEST_REAL_OD unset}" "$@"
SH
  chmod +x "$fakebin/od"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_REAL_OD="$real_od" FM_TEST_REAL_PS="$real_ps" \
    FM_TEST_IDENTITY_FAILURE_READY="$ready" FM_TEST_IDENTITY_FAILURE_LOG="$fail_log" \
    "$WATCH_ARM" > "$armout" 2> "$armerr" &
  armpid=$!
  arm_identity=$(fm_test_pid_identity "$armpid" 2>/dev/null || true)
  [ -n "$arm_identity" ] || fail "could not bind identity-unavailable arm"
  arm_cleanup_active=1
  trap 'cleanup_arm_preconfirmation_probe' EXIT

  i=0
  while [ "$i" -lt 160 ] && [ ! -s "$ready" ]; do
    "$real_sleep" 0.05
    i=$((i + 1))
  done
  [ -s "$ready" ] || fail "arm did not enter the deterministic full-identity failure path"
  child_pid=$(sed -n 's/^child_pid=//p' "$ready")
  case "$child_pid" in ''|*[!0-9]*) fail "identity failure published an invalid child PID" ;; esac

  i=0
  while [ "$i" -lt 160 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child_pid" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    "$real_sleep" 0.05
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child_pid" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not establish normally while arm identity reads failed"
  [ -s "$fail_log" ] || fail "full-identity failure seam did not reject an arm read"
  child_parent=$("$real_ps" -p "$child_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  [ "$child_parent" = "$armpid" ] || fail "identity-unavailable watcher was not the exact direct child"
  child_identity=$(fm_test_pid_identity "$child_pid" 2>/dev/null || true)
  [ -n "$child_identity" ] || fail "test could not bind the identity-unavailable watcher for containment"

  "$real_sleep" 60 &
  sentinel_pid=$!
  sentinel_identity=$(fm_test_pid_identity "$sentinel_pid" 2>/dev/null || true)
  [ -n "$sentinel_identity" ] || fail "could not bind identity-unavailable sentinel"

  kill -HUP "$armpid" 2>/dev/null || fail "could not interrupt identity-unavailable arm"
  wait_for_exit "$armpid" 160
  status=$?
  is_live_non_zombie "$child_pid" && child_survived=1
  test_pid_matches_identity "$sentinel_pid" "$sentinel_identity" && sentinel_untouched=1
  lifecycle_row=$(tail -1 "$state/.watch-cycle-exits.log" 2>/dev/null || true)

  cleanup_identity_bound_arm_pair \
    "$armpid" "$arm_identity" "$child_pid" "$child_identity" 0 \
    || fail "identity-unavailable RED containment could not retire its exact processes"
  if test_pid_matches_identity "$sentinel_pid" "$sentinel_identity"; then
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  sentinel_pid=
  sentinel_identity=
  arm_cleanup_active=0
  trap - EXIT

  [ "$status" -eq 129 ] || fail "identity-unavailable HUP returned $status instead of 129"
  [ "$child_survived" -eq 0 ] || fail "identity-unavailable HUP forgot the live watcher child"
  [ "$sentinel_untouched" -eq 1 ] || fail "identity-unavailable HUP signalled an unrelated process"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 \
    || fail "identity-unavailable HUP left temp output behind"
  case "$lifecycle_row" in
    "arm_pid=$armpid"$'\t'"watcher_pid=$child_pid"$'\t'*$'\t'"exit_code=129"$'\t'"signal=HUP"$'\t'"reason=arm-interrupted"$'\t'*) ;;
    *) fail "identity-unavailable HUP did not retain the exact lifecycle row: $lifecycle_row" ;;
  esac
  pass "HUP reaps the exact child when arm full-identity reads are unavailable"
)

test_arm_unbound_cleanup_uses_proc_without_ps_o() (
  local dir state fakebin armout armerr ready bind_count ps_log proc_stat_log
  local real_cat real_ps real_sleep armpid arm_identity child_pid child_parent child_identity
  local sentinel_pid sentinel_identity status i lifecycle_row child_survived=0 sentinel_untouched=0
  local arm_cleanup_active observed_bind_count
  dir=$(make_case arm-unbound-cygwin)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armerr="$dir/arm.err"
  ready="$dir/unbound.ready"
  bind_count="$dir/bind-count"
  ps_log="$dir/cygwin-ps.log"
  proc_stat_log="$dir/proc-stat.log"
  real_cat=$(command -v cat)
  real_ps=$(command -v ps)
  real_sleep=$(command -v sleep)
  mark_pr_check_migration_complete "$state"
  printf '0\n' > "$bind_count"
  arm_cleanup_active=0
  child_pid=
  child_identity=
  sentinel_pid=
  sentinel_identity=

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = -o ]; then
    printf '%s\n' "$*" >> "${FM_TEST_CYGWIN_PS_LOG:?FM_TEST_CYGWIN_PS_LOG unset}"
    exit 64
  fi
done
exec "${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" "$@"
SH
  chmod +x "$fakebin/ps"

  # Make the arm miss all 50 startup lifetime-bind attempts while allowing the
  # watcher to read its own real /proc identity. The next arm read succeeds, so
  # cleanup can prove the exact direct child from compatible stat fields even
  # though Cygwin-like ps rejects every -o query.
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  /proc/[0-9]*/stat)
    target=${last%/stat}
    target=${target##*/}
    ancestor=$PPID
    self_read=0
    while [ "$ancestor" -gt 1 ]; do
      if [ "$ancestor" = "$target" ]; then
        self_read=1
        break
      fi
      ancestor=$("${FM_TEST_REAL_PS:?FM_TEST_REAL_PS unset}" -p "$ancestor" -o ppid= 2>/dev/null | tr -d '[:space:]')
      case "$ancestor" in ''|*[!0-9]*) break ;; esac
    done
    if [ "$self_read" -eq 0 ]; then
      count=$("${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" \
        "${FM_TEST_BIND_COUNT:?FM_TEST_BIND_COUNT unset}" 2>/dev/null || printf '0\n')
      count=$((count + 1))
      tmp="${FM_TEST_BIND_COUNT}.$$"
      printf '%s\n' "$count" > "$tmp"
      mv -f "$tmp" "$FM_TEST_BIND_COUNT"
      if [ "$count" -le 50 ]; then
        tmp="${FM_TEST_UNBOUND_READY:?FM_TEST_UNBOUND_READY unset}.$$"
        printf 'child_pid=%s\n' "$target" > "$tmp"
        mv -f "$tmp" "$FM_TEST_UNBOUND_READY"
        exit 1
      fi
    fi
    line=$("${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" "$last") || exit 1
    printf '%s\n' "$target" >> "${FM_TEST_PROC_STAT_LOG:?FM_TEST_PROC_STAT_LOG unset}"
    printf '%s (watcher ) with spaces)%s\n' "$target" "${line##*)}"
    exit 0
    ;;
esac
exec "${FM_TEST_REAL_CAT:?FM_TEST_REAL_CAT unset}" "$@"
SH
  chmod +x "$fakebin/cat"

  if FM_TEST_CYGWIN_PS_LOG="$ps_log" FM_TEST_REAL_PS="$real_ps" \
    "$fakebin/ps" -p "$$" -o ppid= >/dev/null 2>&1; then
    fail "Cygwin-like unbound fixture unexpectedly accepted ps -o"
  fi
  : > "$ps_log"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_REAL_CAT="$real_cat" FM_TEST_REAL_PS="$real_ps" \
    FM_TEST_BIND_COUNT="$bind_count" FM_TEST_UNBOUND_READY="$ready" \
    FM_TEST_CYGWIN_PS_LOG="$ps_log" FM_TEST_PROC_STAT_LOG="$proc_stat_log" \
    "$WATCH_ARM" > "$armout" 2> "$armerr" &
  armpid=$!
  arm_identity=$(fm_test_pid_identity "$armpid" 2>/dev/null || true)
  [ -n "$arm_identity" ] || fail "could not bind Cygwin-like unbound arm identity"
  arm_cleanup_active=1
  trap 'cleanup_arm_preconfirmation_probe' EXIT

  i=0
  while [ "$i" -lt 160 ] && [ ! -s "$ready" ]; do
    "$real_sleep" 0.05
    i=$((i + 1))
  done
  [ -s "$ready" ] || fail "arm did not enter the deterministic unbound-child path"
  child_pid=$(sed -n 's/^child_pid=//p' "$ready")
  case "$child_pid" in ''|*[!0-9]*) fail "unbound fixture published an invalid child PID" ;; esac
  child_parent=$("$real_ps" -p "$child_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  [ "$child_parent" = "$armpid" ] || fail "unbound watcher was not the arm's exact direct child"
  child_identity=$(fm_test_pid_identity "$child_pid" 2>/dev/null || true)
  [ -n "$child_identity" ] || fail "could not bind unbound watcher identity for containment"

  "$real_sleep" 60 &
  sentinel_pid=$!
  sentinel_identity=$(fm_test_pid_identity "$sentinel_pid" 2>/dev/null || true)
  [ -n "$sentinel_identity" ] || fail "could not bind unbound-cleanup sentinel"

  wait_for_exit "$armpid" 200
  status=$?
  is_live_non_zombie "$child_pid" && child_survived=1
  test_pid_matches_identity "$sentinel_pid" "$sentinel_identity" && sentinel_untouched=1
  lifecycle_row=$(tail -1 "$state/.watch-cycle-exits.log" 2>/dev/null || true)
  observed_bind_count=$("$real_cat" "$bind_count" 2>/dev/null || true)

  cleanup_identity_bound_arm_pair \
    "$armpid" "$arm_identity" "$child_pid" "$child_identity" 0 \
    || fail "unbound RED containment could not retire its exact processes"
  if test_pid_matches_identity "$sentinel_pid" "$sentinel_identity"; then
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  sentinel_pid=
  sentinel_identity=
  arm_cleanup_active=0
  trap - EXIT

  [ "$status" -eq 1 ] || fail "unbound startup failure returned $status instead of 1"
  [ "$child_survived" -eq 0 ] || fail "unbound cleanup forgot the exact spawned watcher"
  [ "$sentinel_untouched" -eq 1 ] || fail "unbound cleanup signalled an unrelated process"
  [ "$observed_bind_count" -gt 50 ] \
    || fail "unbound cleanup never consumed a post-bind /proc snapshot"
  grep -Fx "$child_pid" "$proc_stat_log" >/dev/null \
    || fail "unbound cleanup did not parse the compatible child stat snapshot"
  [ ! -s "$ps_log" ] \
    || fail "unbound cleanup invoked unsupported ps -o: $(tr '\n' ';' < "$ps_log")"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 \
    || fail "unbound cleanup left temp output behind"
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
    || fail "unbound cleanup left watcher lock evidence"
  case "$lifecycle_row" in
    "arm_pid=$armpid"$'\t'"watcher_pid=$child_pid"$'\t'*$'\t'"exit_code=1"$'\t'"signal=none"$'\t'"reason=startup-identity-bind-failed"$'\t'*) ;;
    *) fail "unbound cleanup did not retain the exact startup failure lifecycle row: $lifecycle_row" ;;
  esac
  pass "unbound watcher cleanup uses compatible /proc fields without ps -o"
)

test_arm_hup_ignores_ambient_grace_and_cleans_foreground() {
  local hostile log rc
  for hostile in 1 999999; do
    log="$TMP_ROOT/arm-hup-hostile-grace-$hostile.log"
    rc=0
    FM_TEST_ARM_HUP_STOPPED_CHILD=1 FM_TEST_ARM_HUP_EXIT_POLLS=80 \
      FM_ARM_SHUTDOWN_GRACE_POLLS="$hostile" bash "$0" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$log" >&2
      fail "ambient shutdown grace '$hostile' changed bounded stopped-watcher cleanup (status $rc)"
    fi
    grep -F 'ok - arm cleans child watcher and temp output on HUP' "$log" >/dev/null \
      || fail "hostile-grace '$hostile' probe did not complete its behavior contract"
  done
  pass "arm ignores ambient grace and cleans a stopped watcher's foreground command without collateral signaling"
}

test_arm_hup_preserves_caller_traps() {
  local dir noop before after after_source probe_rc changed=0
  dir=$(make_case arm-hup-trap-state)
  noop="$dir/noop.sh"
  before="$dir/traps.before"
  after="$dir/traps.after"
  after_source="$dir/traps.after-source"
  printf ':\n' > "$noop"

  trap -p EXIT INT TERM RETURN > "$before"
  test_arm_hup_cleans_child_and_temp_output
  probe_rc=$?
  [ "$probe_rc" -eq 0 ] || fail "normal HUP cleanup probe exited $probe_rc"
  trap -p EXIT INT TERM RETURN > "$after"
  # A leaked RETURN handler fires at the end of a sourced file and can erase
  # inherited test cleanup traps after the HUP fixture itself appeared done.
  # Source one no-op so both the immediate and deferred trap state are proven.
  # shellcheck source=/dev/null
  . "$noop"
  trap -p EXIT INT TERM RETURN > "$after_source"

  cmp -s "$before" "$after" || changed=1
  cmp -s "$before" "$after_source" || changed=1
  if [ "$changed" -ne 0 ]; then
    printf '%s\n' '--- trap state immediately after normal HUP ---' >&2
    diff -u "$before" "$after" >&2 || true
    printf '%s\n' '--- trap state after sourcing a no-op ---' >&2
    diff -u "$before" "$after_source" >&2 || true
    fail "normal HUP fixture changed its caller's EXIT/INT/TERM/RETURN traps"
  fi
  pass "normal HUP fixture preserves caller traps across a later source return"
}

test_arm_hup_scoped_cleanup_on_forced_term() {
  local evidence log rc arm_pid arm_identity watcher_pid watcher_identity fixture_dir stage
  local cleanup_report arm_was_live=0 watcher_was_live=0 rescue_rc=0 log_size
  evidence="$TMP_ROOT/arm-hup-forced-term-evidence"
  log="$TMP_ROOT/arm-hup-forced-term.log"
  mkdir -p "$evidence"
  FM_TEST_FORCE_ARM_HUP_TERM=1 FM_TEST_ARM_HUP_CLEANUP_EVIDENCE="$evidence" \
    bash "$0" > "$log" 2>&1
  rc=$?

  arm_pid=$(cat "$evidence/arm.pid" 2>/dev/null || true)
  arm_identity=$(cat "$evidence/arm.identity" 2>/dev/null || true)
  watcher_pid=$(cat "$evidence/watcher.pid" 2>/dev/null || true)
  watcher_identity=$(cat "$evidence/watcher.identity" 2>/dev/null || true)
  fixture_dir=$(cat "$evidence/fixture-dir" 2>/dev/null || true)
  stage=$(cat "$evidence/stage" 2>/dev/null || true)
  cleanup_report=$(cat "$evidence/cleanup.rc" 2>/dev/null || true)
  test_pid_matches_identity "$arm_pid" "$arm_identity" && arm_was_live=1
  test_pid_matches_identity "$watcher_pid" "$watcher_identity" && watcher_was_live=1

  # RED may leave the exact probe pair alive. Rescue it before asserting so the
  # archived failure cannot leave a stopped watcher or an unbounded error log.
  cleanup_identity_bound_arm_pair \
    "$arm_pid" "$arm_identity" "$watcher_pid" "$watcher_identity" 0 || rescue_rc=$?
  log_size=$(wc -c < "$log" | tr -d '[:space:]')

  [ "$rescue_rc" -eq 0 ] || fail "forced-TERM probe rescue could not retire its identity-bound processes"
  [ "$rc" -eq 143 ] || fail "forced-TERM cleanup probe exited $rc instead of 143"
  [ "$stage" = watcher-stopped ] || fail "forced-TERM cleanup probe did not reach the SIGSTOP window"
  [ "$cleanup_report" = 0 ] || fail "forced-TERM scoped cleanup reported '$cleanup_report' instead of 0"
  [ "$arm_was_live" -eq 0 ] || fail "forced-TERM cleanup left the owned arm alive"
  [ "$watcher_was_live" -eq 0 ] || fail "forced-TERM cleanup left the stopped owned watcher alive"
  [ -n "$fixture_dir" ] && [ ! -e "$fixture_dir" ] \
    || fail "forced-TERM cleanup left its owned fixture state"
  [ "$log_size" -lt 65536 ] || fail "forced-TERM cleanup produced an unbounded error log ($log_size bytes)"
  pass "forced TERM in the SIGSTOP window reaps only its owned arm and watcher"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  # This case asserts wake propagation, not the confirmation deadline, and its
  # child must also run the registered check before exiting: measured at 1.9-2.3s
  # idle but 9.1-13.1s at 3x CPU oversubscription, against an 11s production
  # budget. An explicit budget takes the deadline out of the assertion and costs
  # nothing on a passing run, because the arm returns as soon as the child
  # settles (issue #2844).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=60 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Same budget contract as the self-eviction case: the owned child's real
  # startup and stand-down happen inside the arm's confirmation window, so the
  # window stays production-sized (issue #2844).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same budget the arm spends made this
  # regression fixture race the confirmation deadline under full-suite load,
  # rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  mark_pr_check_migration_complete "$state"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"
  drain_and_ack "$state" || fail "first ledger wake handling acknowledgement failed"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true
  # The forced interruption is a watcher-down interval. Consume the prior
  # delivered wake before beginning independent ledger cycles, just as the
  # recovery handling turn does, so this fixture does not intentionally carry a
  # durable wake into the next arm.
  drain_and_ack "$state" || fail "recovery drain after forced arm interruption failed"

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    drain_and_ack "$state" \
      || fail "recovery drain after bounded ledger cycle $iteration failed"
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc fakebin locale_log baseline via_lc_all via_lc_time
  local real_first real_second observed
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  fakebin="$TMP_ROOT/locale-ps"
  locale_log="$TMP_ROOT/locale-ps.observed"
  mkdir -p "$fakebin"
  : > "$locale_log"
  # The stub renders lstart through date under whatever locale it inherits, so its
  # output really does change when the caller's locale leaks through. Dropping the
  # LC_ALL=C pin in fm_pid_identity therefore breaks the equality assertions below
  # on any host with a second locale installed, and the recorded LC_ALL below keeps
  # the pin asserted even where ko_KR.UTF-8 is missing and date falls back to C.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$FAKE_PS_LOCALE_LOG"
stamp=$(date -d @1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp=$(date -r 1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp='Mon Jul 28 20:00:00 2026'
printf '%s sleep 300\n' "$stamp"
SH
  chmod +x "$fakebin/ps"
  baseline=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  # Keep the real ps fallback exercised wherever it supports the portable -o fields.
  real_first=
  real_second=
  if LC_ALL=C ps -p "$live" -o lstart= -o command= >/dev/null 2>&1; then
    real_first=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    real_second=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  while read -r observed; do
    [ "$observed" = C ] || fail "fm_pid_identity invoked ps without pinning LC_ALL=C (saw '$observed')"
  done < "$locale_log"
  if [ -n "$real_first" ]; then
    [ "$real_second" = "$real_first" ] \
      || fail "real ps fallback varied with exported LC_TIME (got '$real_second', want '$real_first')"
    pass "fm_pid_identity real ps fallback is locale-invariant"
  else
    pass "real ps fallback locale check skipped where ps -o lstart= is unsupported"
  fi
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse() {
  local dir state proc_root pid identity_key before after_time_jump after_pid_reuse
  dir=$(make_case proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  pid=4242
  identity_key=proc-starttime
  [ "$(uname)" != Linux ] || identity_key=linux-starttime
  mkdir -p "$proc_root"
  printf 'btime 1784094040\n' > "$proc_root/stat"
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read initial fake Linux process identity"
  printf 'btime 1784094016\n' > "$proc_root/stat"
  after_time_jump=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "/proc process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = "$identity_key=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700" ] \
    || fail "/proc process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "/proc process identity ignores simulated btime changes"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read reused fake /proc pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "/proc process identity missed changed starttime for reused pid"
  pass "/proc process identity detects pid reuse"
}

test_proc_identity_disappearance_does_not_switch_to_ps() (
  local dir state proc_root fakebin ps_log live before after alive_before=0 alive_after=0
  dir=$(make_case proc-identity-disappears)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/fakebin"
  ps_log="$dir/ps.log"
  mkdir -p "$proc_root" "$fakebin"
  sleep 300 &
  live=$!
  write_fake_proc_identity "$proc_root" "$live" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not read identity before the per-PID /proc entry disappeared"
  FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$live" \
    && alive_before=1

  rm -f -- "$proc_root/$live/stat" "$proc_root/$live/cmdline"
  rmdir -- "$proc_root/$live"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_PS_LOG:?FM_TEST_PS_LOG unset}"
exit 64
SH
  chmod +x "$fakebin/ps"
  after=$(PATH="$fakebin:$PATH" FM_TEST_PS_LOG="$ps_log" \
    FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null || true)
  kill -0 "$live" 2>/dev/null && alive_after=1
  kill -TERM "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  [ -n "$before" ] || fail "pre-disappearance /proc identity was empty"
  [ "$alive_before" -eq 1 ] || fail "fixture process was not live before /proc disappearance"
  [ "$alive_after" -eq 1 ] || fail "fixture process did not remain live across simulated /proc disappearance"
  [ -z "$after" ] || fail "missing per-PID /proc entry produced an unexpected identity: $after"
  [ ! -s "$ps_log" ] \
    || fail "per-PID /proc disappearance fell back to ps: $(tr '\n' ';' < "$ps_log")"
  pass "per-PID /proc disappearance is an identity mismatch without ps fallback"
)

test_stale_watch_reclaim_publishes_before_clear() {
  local dir state lockdir rc token
  dir=$(make_case stale-watch-publish-before-clear)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir"
  printf '99999999\n' > "$lockdir/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_remove_path() {
      if [ "$1" = "$STATE/.watch.lock" ]; then
        kill -KILL "${BASHPID:-$$}"
      fi
      return 1
    }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted stale watcher reclaim unexpectedly completed"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] \
    || fail "stale watcher lock cleared before recovery publication boundary"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$LIB" "$state/.watcher-down") \
    || fail "stale watcher reclaim interruption left no durable recovery evidence"
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale watcher reclaim published invalid recovery evidence: $token" ;;
  esac

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" \
    || fail "successor could not reclaim watcher lock after interrupted clear"
  pass "stale watcher reclaim publishes durable recovery evidence before clear"
}

test_msys_pid_identity_uses_proc() {
  local live identity
  case "$(uname)" in
    MSYS*|MINGW*|CYGWIN*) ;;
    *)
      pass "MSYS /proc process identity regression skipped on non-Windows host"
      return
      ;;
  esac
  sleep 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$identity" in
    proc-starttime=*" cmdline-hex="*) ;;
    *) fail "MSYS process identity did not use compatible /proc fields ('$identity')" ;;
  esac
  pass "MSYS process identity uses compatible /proc fields"
}

if [ "${FM_TEST_ARM_HUP_STOPPED_CHILD:-0}" = 1 ]; then
  test_arm_hup_cleans_child_and_temp_output
  exit $?
fi

if [ "${FM_TEST_ARM_PORTABLE_PS:-0}" = 1 ]; then
  test_arm_hup_cleans_child_and_temp_output
  exit $?
fi

if [ "${FM_TEST_FORCE_ARM_HUP_TERM:-0}" = 1 ]; then
  test_arm_hup_cleans_child_and_temp_output
  exit $?
fi

if [ "${FM_TEST_ARM_PRECONFIRMATION_HUP:-0}" = 1 ]; then
  test_arm_preconfirmation_signal_reaps_exact_spawned_child
  exit $?
fi

if [ "${FM_TEST_ARM_IDENTITY_UNAVAILABLE:-0}" = 1 ]; then
  test_arm_signal_reaps_child_when_full_identity_is_unavailable
  exit $?
fi

if [ "${FM_TEST_ARM_UNBOUND_CYGWIN:-0}" = 1 ]; then
  test_arm_unbound_cleanup_uses_proc_without_ps_o
  exit $?
fi

if [ "${FM_TEST_PROC_IDENTITY_DISAPPEAR:-0}" = 1 ]; then
  test_proc_identity_disappearance_does_not_switch_to_ps
  exit $?
fi

test_singleton_start
test_pid_identity_is_locale_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_proc_identity_disappearance_does_not_switch_to_ps
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_scoped_cleanup_on_forced_term
test_arm_preconfirmation_signals_reap_exact_spawned_child
test_arm_cygwin_ps_preconfirmation_signals_reap_exact_spawned_child
test_arm_signal_reaps_child_when_full_identity_is_unavailable
test_arm_unbound_cleanup_uses_proc_without_ps_o
test_arm_portable_ps_snapshot_cleans_child
test_arm_hup_preserves_caller_traps
test_arm_hup_ignores_ambient_grace_and_cleans_foreground
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
