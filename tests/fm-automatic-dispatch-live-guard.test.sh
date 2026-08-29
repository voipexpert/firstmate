#!/usr/bin/env bash
# Portable guard coverage for the opt-in live automatic-dispatch test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/tests/fm-automatic-dispatch-live-e2e.test.sh"
LAB=$(fm_test_tmproot fm-automatic-dispatch-live-guard)
FAKEBIN="$LAB/fakebin"
CODEX_DIR="$LAB/codex"
CANDIDATE="$LAB/candidate"
PI_AUDIT="$LAB/pi-state-paths"
mkdir -p "$FAKEBIN" "$CODEX_DIR" "$CANDIDATE/state"
printf '%s\n' 'state/.pi-*-extension-loaded' >"$CANDIDATE/.gitignore"
git -C "$CANDIDATE" init -q

cat >"$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '%s\n' '9.9.9 (Claude Code)'
    exit "${FAKE_CLAUDE_VERSION_EXIT:-0}"
    ;;
  --help) printf '%s\n' '  --model <model> aliases include sonnet' ;;
  *) exit 64 ;;
esac
SH
cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 64
printf '%s\n' 'codex-cli 9.9.9'
SH
cat >"$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
state_root=${FM_STATE_OVERRIDE:-${FAKE_PI_DEFAULT_STATE:?}}
mkdir -p "$state_root"
printf '%s\n' watch >"$state_root/.pi-watch-extension-loaded"
printf '%s\n' turnend >"$state_root/.pi-turnend-extension-loaded"
printf '%s\n' "$state_root" >>"${FAKE_PI_AUDIT:?}"
if [ "${FAKE_PI_INTERRUPT:-0}" = 1 ] && [ "${1:-}" = --version ]; then
  while [ ! -s "${FAKE_PI_SIGNAL_FILE:?}" ]; do :; done
  signal_pid=$(sed -n '1p' "$FAKE_PI_SIGNAL_FILE")
  kill -TERM "$signal_pid"
  exit 143
fi
case "${1:-}" in
  --version)
    printf '%s\n' '9.9.9'
    exit "${FAKE_PI_VERSION_EXIT:-0}"
    ;;
  --list-models)
    cat <<'ROWS'
provider model context max-out thinking images
cliproxyapi gemini-3.7-flash-high 1M 16K yes yes
zai glm-5.3 1M 16K yes no
cliproxyapi kimi-k3 1M 16K yes yes
cliproxyapi grok-4.6 500K 16K yes yes
ROWS
    ;;
  *) exit 64 ;;
esac
SH
cat >"$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'quota-axi 9.9.9' ;;
  --json) printf '%s\n' '{"schemaVersion":5,"providers":[]}' ;;
  *) exit 64 ;;
esac
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex" "$FAKEBIN/pi" "$FAKEBIN/quota-axi"

jq -n '{models:[{slug:"gpt-5.6-sol"},{slug:"gpt-5.6-luna"}]}' >"$CODEX_DIR/models_cache.json"

assert_no_cleanup_registry() {
  local directory=$1 leaked
  leaked=$(find "$directory" -maxdepth 1 -name '.fm-test-cleanup.*' -print)
  [ -z "$leaked" ] || fail "live guard leaked cleanup registry: $leaked"
}

run_live() {
  local case_tmp=$1
  shift
  mkdir -p "$case_tmp"
  (
    cd "$CANDIDATE" || exit 1
    TMPDIR="$case_tmp" PATH="$FAKEBIN:$PATH" CODEX_HOME="$CODEX_DIR" \
      FAKE_PI_DEFAULT_STATE="$CANDIDATE/state" FAKE_PI_AUDIT="$PI_AUDIT" \
      "$@" "$LIVE"
  )
}

candidate_marker_inventory() {
  local marker
  for marker in .pi-watch-extension-loaded .pi-turnend-extension-loaded; do
    if [ -e "$CANDIDATE/state/$marker" ]; then
      printf '%s present %s\n' "$marker" "$(cksum <"$CANDIDATE/state/$marker")"
    else
      printf '%s absent\n' "$marker"
    fi
  done
}

assert_disposable_pi_state_cleaned() {
  local state_root
  [ -s "$PI_AUDIT" ] || fail "Pi probe did not record its scoped state root"
  while IFS= read -r state_root; do
    case "$state_root" in
      "$CANDIDATE"/*) fail "Pi probe used candidate state: $state_root" ;;
    esac
    [ ! -e "$state_root" ] || fail "live guard leaked disposable Pi state: $state_root"
  done <"$PI_AUDIT"
}

test_skip_does_not_create_cleanup_registry() {
  local case_tmp="$LAB/skip" out
  out=$(run_live "$case_tmp" env -u FM_AUTOMATIC_DISPATCH_LIVE_E2E) \
    || fail "live guard opt-in skip failed"
  assert_contains "$out" 'skip: set FM_AUTOMATIC_DISPATCH_LIVE_E2E=1' "live guard skip diagnostic"
  assert_no_cleanup_registry "$case_tmp"
  pass "live guard skip creates no cleanup registry"
}

test_nonzero_version_with_output_fails_before_reporting() {
  local case_tmp="$LAB/version-failure" out rc
  set +e
  out=$(run_live "$case_tmp" env FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 FAKE_CLAUDE_VERSION_EXIT=42 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "nonzero Claude version probe was hidden by first-line extraction"
  assert_contains "$out" 'Claude version probe failed' "nonzero version probe diagnostic"
  assert_not_contains "$out" 'runtime claude version=' "failed version probe was reported as installed"
  assert_no_cleanup_registry "$case_tmp"
  pass "nonzero version output is never mistaken for a successful probe"
}

test_success_composes_shared_cleanup() {
  local case_tmp="$LAB/success" out before after
  : >"$PI_AUDIT"
  before=$(candidate_marker_inventory)
  out=$(run_live "$case_tmp" env FM_AUTOMATIC_DISPATCH_LIVE_E2E=1) \
    || fail "fake live verification did not complete: $out"
  after=$(candidate_marker_inventory)
  assert_contains "$out" 'ok - live automatic dispatch verified' "fake live verification result"
  [ "$after" = "$before" ] || fail "live probe changed ignored candidate markers: before=[$before] after=[$after]"
  assert_disposable_pi_state_cleaned
  assert_no_cleanup_registry "$case_tmp"
  pass "successful live verification preserves shared cleanup"
}

test_failed_pi_probe_cleans_disposable_state() {
  local case_tmp="$LAB/pi-failure" out rc before after
  : >"$PI_AUDIT"
  before=$(candidate_marker_inventory)
  set +e
  out=$(run_live "$case_tmp" env FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 FAKE_PI_VERSION_EXIT=42 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failing Pi version probe unexpectedly succeeded"
  assert_contains "$out" 'Pi version probe failed' "failing Pi probe diagnostic"
  after=$(candidate_marker_inventory)
  [ "$after" = "$before" ] || fail "failed live probe changed ignored candidate markers: before=[$before] after=[$after]"
  assert_disposable_pi_state_cleaned
  assert_no_cleanup_registry "$case_tmp"
  pass "failed Pi probe cleans disposable state without changing candidate markers"
}

test_interrupted_pi_probe_cleans_disposable_state() {
  local case_tmp="$LAB/pi-interrupt" out_file="$LAB/pi-interrupt.out"
  local signal_file="$LAB/pi-interrupt.pid" live_pid out rc before after
  : >"$PI_AUDIT"
  before=$(candidate_marker_inventory)
  mkdir -p "$case_tmp"
  set +e
  (
    cd "$CANDIDATE" || exit 1
    exec env TMPDIR="$case_tmp" PATH="$FAKEBIN:$PATH" CODEX_HOME="$CODEX_DIR" \
      FAKE_PI_DEFAULT_STATE="$CANDIDATE/state" FAKE_PI_AUDIT="$PI_AUDIT" \
      FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 FAKE_PI_INTERRUPT=1 \
      FAKE_PI_SIGNAL_FILE="$signal_file" "$LIVE"
  ) >"$out_file" 2>&1 &
  live_pid=$!
  printf '%s\n' "$live_pid" >"$signal_file"
  wait "$live_pid"
  rc=$?
  set -e
  out=$(cat "$out_file")
  [ "$rc" -eq 143 ] || fail "interrupted Pi probe exited $rc instead of 143: $out"
  after=$(candidate_marker_inventory)
  [ "$after" = "$before" ] || fail "interrupted live probe changed ignored candidate markers: before=[$before] after=[$after]"
  assert_disposable_pi_state_cleaned
  assert_no_cleanup_registry "$case_tmp"
  pass "interrupted Pi probe cleans disposable state without changing candidate markers"
}

test_skip_does_not_create_cleanup_registry
test_nonzero_version_with_output_fails_before_reporting
test_success_composes_shared_cleanup
test_failed_pi_probe_cleans_disposable_state
test_interrupted_pi_probe_cleans_disposable_state
