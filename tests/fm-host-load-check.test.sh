#!/usr/bin/env bash
# tests/fm-host-load-check.test.sh - bin/fm-host-load-check.sh wakes once per
# sustained high-load episode and stays silent otherwise.
#
# A fake `uptime` (and `ssh`) on PATH supplies the load; FM_HOST_LOAD_NOW
# supplies the clock, so the 30-minute window is exercised without waiting.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-host-load-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-load-check-tests)

make_case() {  # <name>
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/state" "$CASE_DIR/fakebin"
  cat > "$CASE_DIR/fakebin/uptime" <<'SH'
#!/bin/sh
[ "$(cat "$FAKE_LOAD_FILE")" = fail ] && { echo "uptime: broken" >&2; exit 1; }
printf '11:07  up 19 days, 21:31, 1 user, load averages: %s\n' "$(cat "$FAKE_LOAD_FILE")"
SH
  cat > "$CASE_DIR/fakebin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
[ "$(cat "$FAKE_LOAD_FILE")" = fail ] && { echo "ssh: connect to host macmini port 22: Operation timed out" >&2; exit 255; }
printf '11:07  up 19 days, 21:31, 1 user, load averages: %s\n' "$(cat "$FAKE_LOAD_FILE")"
SH
  chmod +x "$CASE_DIR/fakebin/uptime" "$CASE_DIR/fakebin/ssh"
}

# sample <epoch> <loads|fail> [host] -> the check's output
sample() {
  printf '%s\n' "$2" > "$CASE_DIR/load"
  FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$CASE_DIR/state" FM_HOST_LOAD_NOW="$1" \
    FM_HOST_LOAD_HOST="${3:-}" FAKE_LOAD_FILE="$CASE_DIR/load" FAKE_SSH_LOG="$CASE_DIR/ssh.log" \
    PATH="$CASE_DIR/fakebin:$PATH" "$CHECK" check
}

test_sustained_episode_reports_once_and_rearms() {
  local out
  make_case episode
  assert_equals "" "$(sample 1000 '56.80 60.27 62.48' macmini)" "a first high sample must stay silent"
  assert_equals "" "$(sample 1900 '56.80 60.27 62.48' macmini)" "15 minutes high must stay silent"
  out=$(sample 2800 '56.80 60.27 62.48' macmini)
  assert_contains "$out" "host-load: macmini load averages 56.80 60.27 62.48 have stayed above 30 for 30 min" \
    "30 minutes high must print one wake line"
  assert_grep "BatchMode=yes" "$CASE_DIR/ssh.log" "the host load must be read over non-interactive ssh"
  assert_equals "" "$(sample 3100 '56.80 60.27 62.48' macmini)" "the same episode must be reported only once"
  assert_equals "" "$(sample 3400 '12.00 25.00 31.00' macmini)" "a sample not above the threshold on all three must stay silent"
  assert_equals "" "$(sample 3700 '40 40 40' macmini)" "a new episode starts its window over"
  assert_equals "" "$(sample 4300 '40 40 40' macmini)" "ten minutes into the new episode stays silent"
  assert_equals "" "$(sample 4900 '40 40 40' macmini)" "twenty minutes into the new episode stays silent"
  out=$(sample 5500 '40 40 40' macmini)
  assert_contains "$out" "have stayed above 30 for 30 min" "a recovered-then-renewed episode must report again"
  pass "a sustained high-load episode wakes once after the window and re-arms after recovery"
}

test_gap_restarts_the_window() {
  make_case gap
  assert_equals "" "$(sample 1000 '40 40 40')" "first sample silent"
  assert_equals "" "$(sample 3000 '40 40 40')" "a sample after a gap longer than the limit restarts the window"
  assert_equals "" "$(sample 3600 '40 40 40')" "ten minutes into the restarted window stays silent"
  assert_equals "" "$(sample 4200 '40 40 40')" "twenty minutes into the restarted window stays silent"
  assert_contains "$(sample 4800 '40 40 40')" "host-load: localhost" "the restarted window reports once it is full"
  pass "a sampling gap restarts the window instead of assuming continuity"
}

test_read_failure_reports_once_per_episode() {
  local out
  make_case failure
  out=$(sample 1000 fail macmini)
  assert_contains "$out" "host-load: cannot read load from macmini" "a failed read must be reported"
  assert_equals "" "$(sample 1300 fail macmini)" "a repeated failure must stay silent"
  assert_equals "" "$(sample 1600 '1 1 1' macmini)" "a good low read stays silent and re-arms"
  assert_contains "$(sample 1900 fail macmini)" "cannot read load" "a new failure episode reports again"
  pass "an unreadable host is reported once per failure episode"
}

test_arm_registers_and_disarm_retires() {
  local out
  make_case arm
  out=$(FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$CASE_DIR/state" "$CHECK" arm --host macmini --threshold 25 --minutes 20) \
    || fail "arm failed: $out"
  assert_contains "$out" "armed: state/host-load.check.sh" "arm must report the shim"
  assert_present "$CASE_DIR/state/host-load.check-trust" "arm must bind the shim"
  printf '30 30 30\n' > "$CASE_DIR/load"
  FAKE_LOAD_FILE="$CASE_DIR/load" FAKE_SSH_LOG="$CASE_DIR/ssh.log" PATH="$CASE_DIR/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$CASE_DIR/state" FM_HOST_LOAD_NOW=100 "$CASE_DIR/state/host-load.check.sh" >/dev/null
  assert_grep "macmini uptime" "$CASE_DIR/ssh.log" "the armed shim must poll the chosen host"
  out=$(FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$CASE_DIR/state" "$CHECK" disarm) || fail "disarm failed: $out"
  assert_absent "$CASE_DIR/state/host-load.check.sh" "disarm must remove the shim"
  assert_absent "$CASE_DIR/state/host-load.check-trust" "disarm must remove the trust binding"
  assert_absent "$CASE_DIR/state/.host-load" "disarm must remove the episode record"
  pass "arm writes and registers the host shim and disarm retires it"
}

test_sustained_episode_reports_once_and_rearms
test_gap_restarts_the_window
test_read_failure_reports_once_per_episode
test_arm_registers_and_disarm_retires
