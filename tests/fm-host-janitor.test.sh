#!/usr/bin/env bash
# tests/fm-host-janitor.test.sh - bin/fm-host-janitor.sh reports and cleans only
# ownerless leftovers.
#
# Every case drives the real script against real processes. Leftovers are
# orphaned the way a finished worker leaves them: started from a subshell that
# exits, so init (or a Linux per-user systemd subreaper) adopts them.
# FM_HOST_JANITOR_MIN_AGE_SECS=0 stands in for "older than the minimum age".
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JANITOR="$ROOT/bin/fm-host-janitor.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-janitor-tests)
PIDS_TO_CLEAN=""
cleanup_started() {
  local p
  for p in $PIDS_TO_CLEAN; do kill -KILL "$p" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_started EXIT

# start_orphan <pidfile> [NAME=value...] <command...>
# Starts the command orphaned, records its pid for cleanup, and sets STARTED.
start_orphan() {
  local pidfile=$1
  shift
  ( env "$@" >/dev/null 2>&1 & echo $! > "$pidfile" )
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$pidfile" ] && break; sleep 0.1; done
  STARTED=$(cat "$pidfile")
  PIDS_TO_CLEAN="$PIDS_TO_CLEAN $STARTED"
}

alive() { kill -0 "$1" 2>/dev/null && ! ps -p "$1" -o stat= 2>/dev/null | grep -q Z; }

wait_orphaned() {  # <pid>
  local parent
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    parent=$(ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]')
    [ "$parent" = 1 ] && return 0
    ps -p "$parent" -o command= 2>/dev/null | grep -Eq '(^|/)systemd( |$)' && return 0
    sleep 0.1
  done
  fail "setup: pid $1 was never orphaned"
}

run_janitor() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_HOST_JANITOR_GRACE_SECS=2 \
    "$JANITOR" "$@"
}

test_orphaned_temp_server_is_reported_then_cleaned() {
  local case_dir pid out
  case_dir="$TMP_ROOT/orphan"
  mkdir -p "$case_dir/state"
  start_orphan "$case_dir/pid" PYTHONDONTWRITEBYTECODE=1 python3 -m http.server 0 --bind 127.0.0.1
  pid=$STARTED
  wait_orphaned "$pid"
  out=$(FM_HOST_JANITOR_MIN_AGE_SECS=0 run_janitor "$case_dir" 2>&1)
  assert_contains "$out" "$pid" "orphan: dry-run did not report the orphaned http.server"
  assert_contains "$out" "temp-server" "orphan: dry-run did not classify the http.server"
  alive "$pid" || fail "orphan: dry-run signaled a process"
  assert_grep "	dry-run	temp-server	$pid	" "$case_dir/state/host-janitor.log" \
    "orphan: dry-run did not log the finding"
  out=$(run_janitor "$case_dir" 2>&1)
  assert_not_contains "$out" "$pid" "orphan: a process younger than the default minimum age was reported"
  out=$(FM_HOST_JANITOR_MIN_AGE_SECS=0 run_janitor "$case_dir" --apply 2>&1)
  assert_contains "$out" "TERM pid=$pid" "orphan: --apply did not name the signaled pid"
  alive "$pid" && fail "orphan: --apply left the orphaned http.server running"
  assert_grep "	apply	temp-server	$pid	" "$case_dir/state/host-janitor.log" \
    "orphan: --apply did not log the finding"
  pass "an orphaned temp server is reported by dry-run, spared below the minimum age, and cleaned by --apply"
}

test_owned_and_claimed_processes_are_kept() {
  local case_dir owned claimed gone state out
  case_dir="$TMP_ROOT/kept"
  mkdir -p "$case_dir/state" "$case_dir/home-state"
  state=$(cd "$case_dir/home-state" && pwd -P)
  : > "$state/live-task.meta"
  # An owner that is neither a test-run process nor a plain launcher. The
  # server command rides the environment so the owner's own command line
  # does not itself read as a temp server.
  # shellcheck disable=SC2016 # the perl program is single-quoted on purpose
  start_orphan "$case_dir/owner" OWNED_CMD="python3 -m http.server 0 --bind 127.0.0.1" \
    perl -e 'my $p = fork; if (!$p) { exec $ENV{OWNED_CMD} } open(my $f, ">", "'"$case_dir/owned"'"); print $f "$p\n"; close $f; sleep 300'
  owned=$STARTED
  wait_orphaned "$owned"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$case_dir/owned" ] && break; sleep 0.1; done
  owned=$(cat "$case_dir/owned")
  PIDS_TO_CLEAN="$PIDS_TO_CLEAN $owned"
  start_orphan "$case_dir/claimed" FM_TASK_ID=live-task FM_TASK_STATE_DIR="$state" \
    python3 -m http.server 0 --bind 127.0.0.1
  claimed=$STARTED
  start_orphan "$case_dir/gone" FM_TASK_ID=gone-task FM_TASK_STATE_DIR="$state" \
    python3 -m http.server 0 --bind 127.0.0.1
  gone=$STARTED
  wait_orphaned "$claimed"
  wait_orphaned "$gone"
  # A host that cannot read these environments would make the claim cases vacuous.
  # shellcheck source=bin/fm-task-proc-lib.sh disable=SC1091
  ( . "$ROOT/bin/fm-task-proc-lib.sh"; fm_task_proc_markers ) | grep -q "^$claimed	live-task	" \
    || fail "kept: this host cannot read the claimed server's environment"
  out=$(FM_HOST_JANITOR_MIN_AGE_SECS=0 run_janitor "$case_dir" --apply 2>&1)
  alive "$owned" || fail "kept: a server with a long-lived owner was cleaned"
  alive "$claimed" || fail "kept: a server claimed by a live task was cleaned"
  alive "$gone" && fail "kept: a server whose task is gone survived --apply"
  assert_contains "$out" "task gone" "kept: the gone-task server was not reported as task gone"
  assert_not_contains "$out" "pid=$claimed " "kept: the claimed server was signaled"
  pass "owned and live-claimed processes are kept while a gone task's server is cleaned"
}

test_install_writes_an_hourly_apply_agent() {
  local case_dir out agents
  [ "$(uname)" = Darwin ] || { printf 'skip: launchd install is macOS only\n'; return 0; }
  case_dir="$TMP_ROOT/install"
  agents="$case_dir/LaunchAgents"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/launchctl.log"\n' "$case_dir" > "$case_dir/fakebin/launchctl"
  chmod +x "$case_dir/fakebin/launchctl"
  out=$(PATH="$case_dir/fakebin:$PATH" FM_HOST_JANITOR_LAUNCH_AGENTS_DIR="$agents" \
    run_janitor "$case_dir" --install 2>&1) || fail "install: --install failed: $out"
  plutil -lint "$agents/com.firstmate.host-janitor.plist" >/dev/null \
    || fail "install: the plist is not valid"
  assert_grep "<integer>3600</integer>" "$agents/com.firstmate.host-janitor.plist" "install: not hourly"
  assert_grep "<string>--apply</string>" "$agents/com.firstmate.host-janitor.plist" "install: not --apply"
  assert_grep "bootstrap gui/" "$case_dir/launchctl.log" "install: the agent was not loaded"
  PATH="$case_dir/fakebin:$PATH" FM_HOST_JANITOR_LAUNCH_AGENTS_DIR="$agents" \
    run_janitor "$case_dir" --uninstall >/dev/null 2>&1
  assert_absent "$agents/com.firstmate.host-janitor.plist" "uninstall: the plist remains"
  pass "--install writes and loads an hourly --apply launch agent, and --uninstall removes it"
}

test_orphaned_temp_server_is_reported_then_cleaned
test_owned_and_claimed_processes_are_kept
test_install_writes_an_hourly_apply_agent
