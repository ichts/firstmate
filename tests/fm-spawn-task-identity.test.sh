#!/usr/bin/env bash
# tests/fm-spawn-task-identity.test.sh - every ship and scout worker starts with
# the home-scoped task identity bin/fm-task-proc-lib.sh reaps by.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the pane
# exports and launch command the pane actually received, with the harness
# binary replaced by a probe that prints the identity it was started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task-identity)

# make_case <name> <harness> <id>
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

install_identity_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s|%s|%s|%s|%s|%s\n' "${FM_TASK_ID-unset}" "${FM_TASK_STATE_DIR-unset}" \
  "${SIMCTL_CHILD_FM_TASK_ID-unset}" "${SIMCTL_CHILD_FM_TASK_STATE_DIR-unset}" \
  "${TEST_RUNNER_FM_TASK_ID-unset}" "${TEST_RUNNER_FM_TASK_STATE_DIR-unset}"
SH
  chmod +x "$1/$2"
}

# Replay the pane exports, then the launch, in a clean synthetic pane shell.
emitted_identity() {
  local launch preamble
  launch=$(cat "$LAUNCH_LOG")
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane /bin/sh -c "$preamble
$launch"
}

check_ship_identity() {  # <name> <allowlist: absent|empty>
  local name=$1 allowlist=$2 id out status seen state
  id="$name-a1"
  make_case "$name" codex "$id"
  [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "$name: ship spawn should succeed: $out"
  install_identity_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_identity) || fail "$name: the emitted launch failed to run"
  state=$(cd "$HOME_DIR/state" && pwd -P)
  assert_equals "$id|$state|$id|$state|$id|$state" "$seen" \
    "$name: the worker must start with the home-scoped task identity and its Simulator/XCTest carriers"
}

test_ship_identity_ambient() {
  check_ship_identity ship-ambient absent
  pass "a ship worker starts with FM_TASK_ID, the canonical FM_TASK_STATE_DIR, and their carriers"
}

test_ship_identity_through_allowlist() {
  check_ship_identity ship-filtered empty
  pass "an enabled launch-env allowlist keeps the task identity through the cleared environment"
}

test_ship_identity_ambient
test_ship_identity_through_allowlist
