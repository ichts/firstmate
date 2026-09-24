#!/usr/bin/env bash
# fm-host-load-check.sh - wake firstmate when a host's load stays high.
#
# Usage:
#   fm-host-load-check.sh [check]
#   fm-host-load-check.sh arm [--host <ssh-target>] [--threshold <load>] [--minutes <n>]
#   fm-host-load-check.sh disarm
#   fm-host-load-check.sh --help
#
# `check` reads the host's 1-, 5-, and 15-minute load averages from `uptime`
# (over `ssh -o BatchMode=yes <host>` when a host is set, locally otherwise).
# A sample is high when all three exceed the threshold (default 30). It prints
# one line only when samples have stayed high for at least the window
# (default 30 minutes), and prints nothing otherwise, so it composes with the
# watcher's state-check contract: the watcher turns that line into a `check:`
# wake. One sustained episode is reported once; the first sample that is not
# high ends the episode and re-arms the report. A gap longer than
# FM_HOST_LOAD_MAX_GAP_SECS (default 900) between samples restarts the window,
# because continuity across it is unknown. A host that cannot be read is
# reported once per failure episode, and a later successful read re-arms it.
#
# `arm` writes state/host-load.check.sh carrying the chosen host, threshold,
# and window, and binds its bytes with fm-check-register.sh, so the watcher
# runs it on its normal FM_CHECK_INTERVAL cadence. Re-running arm with other
# values replaces the shim. `disarm` retires the shim and its trust binding
# through fm-check-unregister.sh and removes the episode record
# state/.host-load.
#
# The read is bounded by FM_HOST_LOAD_BUDGET_SECS (default 15), cut down to
# fit inside the watcher's own FM_CHECK_TIMEOUT (default 30).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID="host-load"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.host-load"
RECORD_SCHEMA=fm-host-load-v1

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

die_usage() { printf 'fm-host-load-check: %s\n' "$1" >&2; exit 2; }

now_epoch() {
  case "${FM_HOST_LOAD_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_HOST_LOAD_NOW" ;;
  esac
}

is_number() {  # whole or decimal, non-negative
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  return 0
}

# The three load averages, space separated, from uptime text on stdin.
parse_loads() {
  sed -n 's/.*load average[s]*: *//p' | tr -d ',' | awk 'NF >= 3 { print $1, $2, $3; exit }'
}

read_loads() {  # <host> <budget>
  if [ -n "$1" ]; then
    fm_run_timed "$2" ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" uptime 2>&1
  else
    fm_run_timed "$2" uptime 2>&1
  fi
}

record_get() {  # <key>
  [ -f "$RECORD" ] || return 0
  [ "$(sed -n 1p "$RECORD" 2>/dev/null)" = "$RECORD_SCHEMA" ] || return 0
  sed -n "s/^$1=//p" "$RECORD" | head -n 1
}

record_put() {  # <since> <last> <reported> <failed>
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\nsince=%s\nlast=%s\nreported=%s\nfailed=%s\n' \
       "$RECORD_SCHEMA" "$1" "$2" "$3" "$4" > "$tmp" \
     || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

action_check() {
  local host=${FM_HOST_LOAD_HOST:-} threshold=${FM_HOST_LOAD_THRESHOLD:-30}
  local minutes=${FM_HOST_LOAD_MINUTES:-30} gap=${FM_HOST_LOAD_MAX_GAP_SECS:-900}
  local budget=${FM_HOST_LOAD_BUDGET_SECS:-15} timeout=${FM_CHECK_TIMEOUT:-30}
  local out rc=0 loads now since last reported failed high label
  is_number "$threshold" || threshold=30
  case "$minutes" in ''|*[!0-9]*|0) minutes=30 ;; esac
  case "$gap" in ''|*[!0-9]*|0) gap=900 ;; esac
  case "$budget" in ''|*[!0-9]*|0) budget=15 ;; esac
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  [ "$budget" -le $((timeout - 3)) ] || budget=$((timeout - 3))
  [ "$budget" -ge 1 ] || budget=1
  label=${host:-localhost}
  mkdir -p "$STATE" || return 1
  now=$(now_epoch)
  since=$(record_get since)
  last=$(record_get last)
  reported=$(record_get reported)
  failed=$(record_get failed)
  out=$(read_loads "$host" "$budget") || rc=$?
  loads=$(printf '%s\n' "$out" | parse_loads)
  if [ "$rc" -ne 0 ] || [ -z "$loads" ]; then
    if [ "$failed" != 1 ]; then
      printf 'host-load: cannot read load from %s: %s\n' "$label" \
        "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    fi
    record_put "$since" "$last" "$reported" 1 || true
    return 0
  fi
  high=$(printf '%s\n' "$loads" | awk -v t="$threshold" '{ print ($1 > t && $2 > t && $3 > t) ? 1 : 0 }')
  if [ "$high" != 1 ]; then
    record_put "" "$now" 0 0 || true
    return 0
  fi
  case "$last" in ''|*[!0-9]*) since= ;; *) [ $((now - last)) -le "$gap" ] || since= ;; esac
  case "$since" in ''|*[!0-9]*) since=$now; reported=0 ;; esac
  if [ "$reported" != 1 ] && [ $((now - since)) -ge $((minutes * 60)) ]; then
    printf 'host-load: %s load averages %s have stayed above %s for %s min\n' \
      "$label" "$loads" "$threshold" "$(((now - since) / 60))"
    reported=1
  fi
  record_put "$since" "$now" "${reported:-0}" 0 || true
  return 0
}

action_arm() {
  local host="" threshold=30 minutes=30 home tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host) [ "$#" -ge 2 ] || die_usage "--host needs a value"; host=$2; shift ;;
      --threshold) [ "$#" -ge 2 ] || die_usage "--threshold needs a value"; threshold=$2; shift ;;
      --minutes) [ "$#" -ge 2 ] || die_usage "--minutes needs a value"; minutes=$2; shift ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift
  done
  is_number "$threshold" || die_usage "--threshold must be a non-negative number"
  case "$minutes" in ''|*[!0-9]*|0) die_usage "--minutes must be a whole number, at least 1" ;; esac
  case "$host" in -*|*[!A-Za-z0-9@._:-]*) die_usage "--host must be a plain ssh target" ;; esac
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
    || { printf 'fm-host-load-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2; return 1; }
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-host-load-check.XXXXXX") || return 1
  {
    printf '%s\n' '#!/usr/bin/env bash' \
      '# Auto-generated by fm-host-load-check.sh - sustained host load poll shim.' \
      "export FM_HOME=$(printf '%q' "$home")" \
      "export FM_HOST_LOAD_HOST=$(printf '%q' "$host")" \
      "export FM_HOST_LOAD_THRESHOLD=$threshold" \
      "export FM_HOST_LOAD_MINUTES=$minutes" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-host-load-check.sh") check"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-host-load-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-host-load-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh (host %s, load > %s for %s min)\n' \
    "$CHECK_ID" "${host:-localhost}" "$threshold" "$minutes"
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$STATE/$CHECK_ID.check-trust" ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  fi
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) shift; action_arm "$@" ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
