#!/usr/bin/env bash
# bin/fm-task-proc-lib.sh - task-identity process attribution and reaping.
#
# Sourced by bin/fm-teardown.sh and bin/fm-host-janitor.sh. Sourcing has no
# side effects. Every function is bash 3.2 compatible (stock macOS bash).
#
# The task identity is the marker pair every ship and scout worker receives
# from bin/fm-spawn.sh before its launch command, so the agent and everything
# it starts inherit it through the process environment:
#   FM_TASK_ID=<task-id>            the task id (also used by fm-test-run.sh)
#   FM_TASK_STATE_DIR=<state-dir>   canonical state directory of the owning home
# The pair is home-scoped: equal task ids in two homes never match each other.
# bin/fm-spawn.sh also exports the same pair with the SIMCTL_CHILD_ prefix, so
# an app a worker starts inside an iOS Simulator with `xcrun simctl launch`
# carries it too, and TEST_RUNNER_ for the XCTest runner xcodebuild starts.
# A task is live exactly while <state-dir>/<task-id>.meta exists.
#
# Limits: the environment read is the process's INITIAL environment (macOS
# `ps -E`, Linux /proc/<pid>/environ), readable only for processes of the same
# user. A process that rewrites its own argv area (next-server's process title)
# hides it, so attribution also follows the parent chain: a process is claimed
# by its nearest marked ancestor-or-self. A process started through launchd or
# another service manager does not inherit the marker. On macOS the state dir
# must not contain whitespace, because `ps -E` output is space separated, and
# macOS withholds the environment of Apple platform binaries (/bin/sleep,
# /bin/bash), so only their marked or unreadable-but-descended position counts.

# The one protected-process classifier, as an awk function both teardown's
# attribution and bin/fm-host-janitor.sh prepend to their programs. A
# protected process is never signaled and its descendants are never
# attributed through it: the captain's own apps (ego, a Google Chrome that is
# not headless, Xcode, the Simulator app and CoreSimulator internals), the
# terminal hosts every worker lives in (herdr, tmux, zellij, cmux), Pi, and
# shared daemons a worker may merely have started first (no-mistakes, the
# remote job worker, lavish-axi, chrome-devtools-axi).
FM_TASK_PROC_AWK_PROTECTED='
    function protected(c) {
      if (c ~ /ego lite|ego Helper|\/ego\.app\//) return 1
      if (c ~ /Google Chrome\.app\// && c !~ /--headless/) return 1
      if (c ~ /Xcode\.app\/|Simulator\.app\/|CoreSimulator|launchd_sim/) return 1
      if (c ~ /(^|\/)(herdr|tmux|zellij|cmux)( |$)/) return 1
      if (c ~ /(^|[\/ ])pi( |$)/) return 1
      if (c ~ /no-mistakes|fm-remote-job-worker|lavish-axi|chrome-devtools-axi/) return 1
      return 0
    }'

# Stable birth identity of a live pid: Linux /proc starttime, else ps lstart.
# Fails when the pid is gone or unreadable. A reused pid gets a new identity.
fm_task_proc_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

# Every process carrying FM_TASK_ID, as TSV: pid task_id state_dir.
# state_dir is empty for a legacy marker that predates FM_TASK_STATE_DIR.
fm_task_proc_markers() {
  local d pid kv id st
  if [ -r /proc/self/environ ]; then
    for d in /proc/[0-9]*; do
      pid=${d#/proc/}
      id=
      st=
      [ -r "$d/environ" ] || continue
      {
        while IFS= read -r -d '' kv; do
          case "$kv" in
            FM_TASK_ID=*) id=${kv#FM_TASK_ID=} ;;
            FM_TASK_STATE_DIR=*) st=${kv#FM_TASK_STATE_DIR=} ;;
          esac
        done < "$d/environ"
      } 2>/dev/null
      [ -n "$id" ] && printf '%s\t%s\t%s\n' "$pid" "$id" "$st"
    done
    return 0
  fi
  # macOS: -E appends the initial environment after the arguments. The LAST
  # occurrence wins so an argument that merely mentions a marker never beats
  # the real environment entry that follows it.
  LC_ALL=C ps -A -wwE -o pid= -o command= 2>/dev/null | awk '
    {
      id = ""; st = ""
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 11) == "FM_TASK_ID=") id = substr($i, 12)
        else if (substr($i, 1, 18) == "FM_TASK_STATE_DIR=") st = substr($i, 19)
      }
      if (id != "") printf "%s\t%s\t%s\n", $1, id, st
    }'
}

# One process-table snapshot as TSV, one row per process:
#   pid ppid etime_secs task_id state_dir command
# task_id/state_dir come from the process's own marker, empty when unmarked
# or unreadable. Fails when the process table cannot be read.
fm_task_proc_snapshot() {
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-proc.XXXXXX") || return 1
  if ! LC_ALL=C ps -A -ww -o pid= -o ppid= -o etime= -o command= > "$tmp/ps" 2>/dev/null \
     || [ ! -s "$tmp/ps" ]; then
    rm -rf "$tmp"
    return 1
  fi
  fm_task_proc_markers > "$tmp/markers" 2>/dev/null || : > "$tmp/markers"
  awk -F'\t' -v OFS='\t' '
    function secs(s,   d, a, p, n) {
      d = 0
      if (index(s, "-") > 0) { split(s, a, "-"); d = a[1]; s = a[2] }
      n = split(s, p, ":")
      if (n == 3) return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]
      if (n == 2) return d * 86400 + p[1] * 60 + p[2]
      return d * 86400 + p[1]
    }
    FILENAME == ARGV[1] { mid[$1] = $2; mst[$1] = $3; next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      pid = line; sub(/[ \t].*/, "", pid); sub(/^[^ \t]+[ \t]+/, "", line)
      ppid = line; sub(/[ \t].*/, "", ppid); sub(/^[^ \t]+[ \t]+/, "", line)
      et = line; sub(/[ \t].*/, "", et); sub(/^[^ \t]+[ \t]*/, "", line)
      if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/) next
      gsub(/\t/, " ", line)
      print pid, ppid, secs(et), mid[pid], mst[pid], line
    }' "$tmp/markers" "$tmp/ps" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

# From a snapshot on stdin, the pids claimed by one task: every process whose
# own marker is <task-id> in <state-dir>, plus every descendant of one, minus
# pid 1, pid <self> and <self>'s ancestors (so a caller running inside a task
# never signals itself or its own parents), and minus every protected process
# and everything below it.
fm_task_proc_claimed_pids() {  # <task-id> <state-dir> <self-pid>
  awk -F'\t' -v id="$1" -v st="$2" -v self="$3" "$FM_TASK_PROC_AWK_PROTECTED"'
    {
      pp[$1] = $2
      kids[$2] = kids[$2] " " $1
      if (protected($6)) guard[$1] = 1
      if ($4 == id && $5 == st) root[$1] = 1
    }
    END {
      p = self
      while (p != "" && p != 0 && p != 1 && !(p in skip)) { skip[p] = 1; p = pp[p] }
      skip[1] = 1
      n = 0
      for (r in root) q[++n] = r
      while (n > 0) {
        p = q[n--]
        if ((p in seen) || (p in guard)) continue
        seen[p] = 1
        m = split(kids[p], c, " ")
        for (i = 1; i <= m; i++) if (c[i] != "") q[++n] = c[i]
      }
      for (p in seen) if (!(p in skip)) print p
    }' | sort -n
}

# From a snapshot on stdin, the booted-simulator UDIDs this task alone claims:
# a device with a process marked <task-id>/<state-dir>, and no marked process
# of any other task in the same device.
fm_task_proc_claimed_sims() {  # <task-id> <state-dir>
  awk -F'\t' -v id="$1" -v st="$2" '
    match($6, /\/CoreSimulator\/Devices\/[0-9A-Fa-f-]+\//) {
      u = substr($6, RSTART + 23, RLENGTH - 24)
      if (length(u) != 36 || $4 == "") next
      if ($4 == id && $5 == st) mine[u] = 1
      else other[u] = 1
    }
    END { for (u in mine) if (!(u in other)) print u }' | sort
}

# True while <pid> is the process born with <identity> and is not a zombie.
fm_task_proc_alive() {  # <pid> <identity>
  local stat
  [ "$(fm_task_proc_identity "$1" 2>/dev/null)" = "$2" ] || return 1
  stat=$(ps -p "$1" -o stat= 2>/dev/null) || return 1
  case "$stat" in *Z*) return 1 ;; esac
  return 0
}

# Terminate pids: TERM, wait up to <grace-secs> for exit, then KILL each
# survivor whose birth identity still matches (a reused pid is never signaled).
# Logs one line per signaled pid to stderr as "<label>: <SIG> pid=<pid> <cmd>".
# Returns non-zero when any identity-matched process still survives.
fm_task_proc_terminate() {  # <label> <grace-secs> <pid>...
  local label=$1 grace=$2 pid identity cmd i waited=0 alive
  local -a term_pids term_ids
  shift 2
  term_pids=()
  term_ids=()
  for pid in "$@"; do
    case "$pid" in ''|*[!0-9]*|0|1) continue ;; esac
    [ "$pid" = "$$" ] && continue
    identity=$(fm_task_proc_identity "$pid") || continue
    cmd=$(ps -p "$pid" -o command= 2>/dev/null | cut -c1-160)
    term_pids+=("$pid")
    term_ids+=("$identity")
    echo "$label: TERM pid=$pid $cmd" >&2
    kill -TERM "$pid" 2>/dev/null || true
  done
  [ "${#term_pids[@]}" -gt 0 ] || return 0
  while :; do
    alive=0
    for i in "${!term_pids[@]}"; do
      if fm_task_proc_alive "${term_pids[$i]}" "${term_ids[$i]}"; then
        alive=1
        break
      fi
    done
    [ "$alive" = 1 ] || return 0
    [ "$waited" -lt $((grace * 5)) ] || break
    sleep 0.2
    waited=$((waited + 1))
  done
  alive=0
  for i in "${!term_pids[@]}"; do
    pid=${term_pids[$i]}
    if fm_task_proc_alive "$pid" "${term_ids[$i]}"; then
      echo "$label: KILL pid=$pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.2
  for i in "${!term_pids[@]}"; do
    if fm_task_proc_alive "${term_pids[$i]}" "${term_ids[$i]}"; then
      echo "$label: pid=${term_pids[$i]} survived KILL" >&2
      alive=1
    fi
  done
  [ "$alive" = 0 ]
}

# Shut down one booted simulator. Fails when simctl is unavailable or refuses.
fm_task_proc_sim_shutdown() {  # <label> <udid>
  command -v xcrun >/dev/null 2>&1 || { echo "$1: xcrun unavailable; simulator $2 left booted" >&2; return 1; }
  echo "$1: shutting down simulator $2" >&2
  xcrun simctl shutdown "$2" >/dev/null 2>&1
}
