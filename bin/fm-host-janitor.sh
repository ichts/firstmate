#!/usr/bin/env bash
# fm-host-janitor.sh - find, and with --apply clean up, ownerless leftovers of
# worker test runs on this host: dev servers, headless browsers, Playwright
# drivers, temporary servers, and idle booted iOS Simulators.
#
# Usage:
#   fm-host-janitor.sh [--dry-run | --apply] [--min-age-hours <n>]
#   fm-host-janitor.sh --install [--min-age-hours <n>]   (macOS launchd, hourly --apply)
#   fm-host-janitor.sh --uninstall
#   fm-host-janitor.sh --status
#   fm-host-janitor.sh --help
#
# The default is --dry-run: it prints and logs what --apply would clean and
# signals nothing. --apply TERMs each leftover (then KILLs it after
# FM_HOST_JANITOR_GRACE_SECS, default 5, when its birth identity still matches)
# and runs `xcrun simctl shutdown` for each idle Simulator.
#
# A process is a leftover only when ALL of these hold:
#   - its command is a known test-run class: a dev server (next-server,
#     next dev/start, vite, webpack dev server, astro/nuxt/remix/wrangler dev),
#     a headless browser (chrome-headless-shell, a Playwright-cached browser,
#     any Chrome/Chromium started with --headless), a Playwright driver or
#     test runner, or a temporary server (python -m http.server, http-server,
#     a python script under /tmp or /var/folders);
#   - it has run for at least the minimum age (default 3 hours;
#     --min-age-hours or FM_HOST_JANITOR_MIN_AGE_HOURS);
#   - it has no owner: the task identity it carries (bin/fm-task-proc-lib.sh)
#     names a task whose record no longer exists, or it has no live task
#     identity and every ancestor up to init is itself a test-run process or a
#     plain launcher (shell, node, npm, pnpm, npx, yarn, bun, uv, python, env,
#     nohup, make) - so a process whose parent chain reaches a terminal
#     multiplexer, an agent, or any other long-lived owner is kept;
#   - neither it nor the chain above it is protected: the protected set
#     bin/fm-task-proc-lib.sh owns (ego, a Google Chrome that is not
#     headless, Xcode, the Simulator app and CoreSimulator internals, herdr,
#     tmux, Pi, and shared daemons such as no-mistakes) is never signaled.
# A process carrying a live task identity (its <state-dir>/<task-id>.meta
# exists) is always kept, whatever its age or parent. Only the topmost
# leftover of a chain is reported; --apply signals it and its unprotected
# descendants.
#
# A booted Simulator is idle when it has been booted for at least the minimum
# age, no process inside it carries a live task identity, and no app inside it
# (a process under data/Containers/Bundle/Application) started within the
# minimum age.
#
# Every run appends one line per finding plus a summary line to
# <state>/host-janitor.log (tab separated: time, mode, kind, pid-or-udid,
# age-seconds, reason, command). The log rotates to host-janitor.log.1 past
# FM_HOST_JANITOR_LOG_MAX_BYTES (default 262144), so it stays bounded.
#
# --install writes ~/Library/LaunchAgents/com.firstmate.host-janitor.plist,
# which runs this script with --apply every hour (StartInterval 3600) for the
# current FM_HOME, and loads it with `launchctl bootstrap gui/<uid>`.
# Run a --dry-run first and review its output before installing.
# --uninstall runs `launchctl bootout` and removes the plist; --status prints
# whether the agent is loaded. Both are safe to repeat.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/host-janitor.log"
LOG_MAX=${FM_HOST_JANITOR_LOG_MAX_BYTES:-262144}
GRACE=${FM_HOST_JANITOR_GRACE_SECS:-5}
LABEL=com.firstmate.host-janitor
PLIST="${FM_HOST_JANITOR_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$LABEL.plist"

# shellcheck source=bin/fm-task-proc-lib.sh
. "$SCRIPT_DIR/fm-task-proc-lib.sh"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

die_usage() { printf 'fm-host-janitor: %s\n' "$1" >&2; exit 2; }

MODE=dry-run
ACTION=scan
MIN_AGE_HOURS=${FM_HOST_JANITOR_MIN_AGE_HOURS:-3}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --min-age-hours)
      [ "$#" -ge 2 ] || die_usage "--min-age-hours needs a value"
      MIN_AGE_HOURS=$2
      shift
      ;;
    --install) ACTION=install ;;
    --uninstall) ACTION=uninstall ;;
    --status) ACTION=status ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done
case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*|0) die_usage "--min-age-hours must be a whole number of hours, at least 1" ;;
esac
case "$GRACE" in ''|*[!0-9]*) GRACE=5 ;; esac
case "$LOG_MAX" in ''|*[!0-9]*) LOG_MAX=262144 ;; esac
MIN_AGE=$((MIN_AGE_HOURS * 3600))
# Test-only override in seconds; never set it for a real host.
case "${FM_HOST_JANITOR_MIN_AGE_SECS:-}" in
  ''|*[!0-9]*) ;;
  *) MIN_AGE=$FM_HOST_JANITOR_MIN_AGE_SECS ;;
esac

log_rotate() {
  local size
  [ -f "$LOG" ] || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]') || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le "$LOG_MAX" ] || mv -f -- "$LOG" "$LOG.1"
}

log_line() {  # <kind> <pid-or-udid> <age> <reason> <command>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" \
    "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | cut -c1-200)" >> "$LOG" 2>/dev/null || true
}

# Live task claims as "<task-id>\t<state-dir>" lines: every distinct identity
# in the snapshot whose task record still exists.
live_claims() {  # <snapshot-file>
  local id st
  awk -F'\t' '$4 != "" && $5 != "" { print $4 "\t" $5 }' "$1" | sort -u \
    | while IFS=$'\t' read -r id st; do
        [ -e "$st/$id.meta" ] && printf '%s\t%s\n' "$id" "$st"
      done
}

# Topmost leftovers as "root<TAB>pid<TAB>age<TAB>class<TAB>reason<TAB>command"
# followed by their unprotected descendants as "desc<TAB>pid<TAB>root".
classify() {  # <snapshot-file> <live-claims-file> <min-age> <self-pid>
  awk -F'\t' -v OFS='\t' -v min="$3" -v self="$4" "$FM_TASK_PROC_AWK_PROTECTED"'
    function base(c,   t) { t = c; sub(/[ ].*/, "", t); sub(/.*\//, "", t); return t }
    function klass(c) {
      if (c ~ /next-server|(^|[\/ ])next (dev|start)( |$)|next\/dist\/bin\/next (dev|start)/) return "dev-server"
      if (c ~ /(^|[\/ ])vite( |$)|vite\/bin\/vite|webpack-dev-server|webpack(-cli)? serve/) return "dev-server"
      if (c ~ /(astro|nuxt|nuxi|remix|wrangler) dev( |$)/) return "dev-server"
      if (c ~ /chrome-headless-shell|ms-playwright\//) return "headless-browser"
      if (c ~ /[Cc]hrom(e|ium)/ && c ~ /--headless/) return "headless-browser"
      if (c ~ /playwright/) return "playwright"
      if (c ~ /-m http\.server|(^|[\/ ])http-server( |$)/) return "temp-server"
      if (c ~ /[Pp]ython/ && c ~ / \/(private\/)?(tmp|var\/tmp|var\/folders)\/[^ ]*\.py( |$)/) return "temp-server"
      return ""
    }
    function launcher(c,   b) {
      b = base(c)
      return b ~ /^(-?(sh|bash|zsh|dash|fish)|node|npm|npx|pnpm|yarn|bun|bunx|uv|uvx|python[0-9.]*|Python|env|nohup|make|timeout|tsx)$/
    }
    # Nearest identity on the chain: live, dead, or none.
    function claim(p,   x, n) {
      x = p; n = 0
      while (x != "" && x != 0 && x != 1 && (x in cmd) && n++ < 256) {
        if (id[x] != "" && st[x] != "") return ((id[x] SUBSEP st[x]) in live) ? "live" : "dead"
        x = pp[x]
      }
      return "none"
    }
    # "orphaned" when every ancestor up to init is a test-run process or a
    # plain launcher; "" when some other owner or a protected process holds it.
    function orphaned(p,   x, n) {
      x = pp[p]; n = 0
      while (n++ < 256) {
        if (x == 1 || x == 0) return 1
        if (!(x in cmd)) return 0
        # A Linux per-user systemd adopts orphans as a subreaper.
        if (cmd[x] ~ /^[^ ]*(^|\/)systemd( |$)/) return 1
        if (protected(cmd[x])) return 0
        if (klass(cmd[x]) == "" && !launcher(cmd[x])) return 0
        x = pp[x]
      }
      return 0
    }
    FILENAME == ARGV[1] { live[$1 SUBSEP $2] = 1; next }
    {
      pp[$1] = $2; age[$1] = $3; id[$1] = $4; st[$1] = $5; cmd[$1] = $6
      kids[$2] = kids[$2] " " $1
      order[++n] = $1
    }
    END {
      x = self
      while (x != "" && x != 0 && x != 1 && !(x in skip)) { skip[x] = 1; x = pp[x] }
      for (i = 1; i <= n; i++) {
        p = order[i]
        if ((p in skip) || protected(cmd[p])) continue
        k = klass(cmd[p]); if (k == "") continue
        c = claim(p)
        if (c == "live") continue
        if (c == "dead") reason = "task gone"
        else if (orphaned(p)) reason = "orphaned"
        else continue
        cand[p] = k; why[p] = reason
      }
      for (p in cand) {
        # Keep only the topmost leftover of a chain.
        x = pp[p]; top = 1; m = 0
        while (x != "" && x != 0 && x != 1 && m++ < 256) { if (x in cand) { top = 0; break } x = pp[x] }
        if (!top || age[p] < min) continue
        print "root", p, age[p], cand[p], why[p], cmd[p]
        q = 0
        stack[++q] = p
        while (q > 0) {
          y = stack[q--]
          cnt = split(kids[y], c2, " ")
          for (j = 1; j <= cnt; j++) {
            z = c2[j]
            if (z == "" || (z in seen2) || (z in skip)) continue
            seen2[z] = 1
            if (protected(cmd[z])) continue
            print "desc", z, p
            stack[++q] = z
          }
        }
      }
    }' "$2" "$1"
}

# Idle booted Simulators as "udid<TAB>age".
idle_simulators() {  # <snapshot-file> <live-claims-file> <min-age>
  local booted
  command -v xcrun >/dev/null 2>&1 || return 0
  booted=$(xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p') || return 0
  [ -n "$booted" ] || return 0
  printf '%s\n' "$booted" | awk -F'\t' -v OFS='\t' -v min="$3" '
    FILENAME == ARGV[1] { live[$1 SUBSEP $2] = 1; next }
    FILENAME == ARGV[2] {
      if (match($6, /\/CoreSimulator\/Devices\/[0-9A-Fa-f-]+\//)) {
        u = substr($6, RSTART + 23, RLENGTH - 24)
        if ($6 ~ /launchd_sim/ && (!(u in boot) || $3 > boot[u])) boot[u] = $3
        if ($4 != "" && (($4 SUBSEP $5) in live)) busy[u] = 1
        if ($6 ~ /\/data\/Containers\/Bundle\/Application\// && $3 < min) busy[u] = 1
      }
      next
    }
    { if (($1 in boot) && boot[$1] >= min && !($1 in busy)) print $1, boot[$1] }
  ' "$2" "$1" -
}

do_scan() {
  local tmp snap claims roots pids line first pid agev klass reason cmd udid count=0 sims=0
  mkdir -p "$STATE" || { echo "fm-host-janitor: cannot create $STATE" >&2; return 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-host-janitor.XXXXXX") || return 1
  snap="$tmp/snapshot"
  claims="$tmp/claims"
  if ! fm_task_proc_snapshot > "$snap"; then
    rm -rf "$tmp"
    echo "fm-host-janitor: cannot read the process table" >&2
    return 1
  fi
  live_claims "$snap" > "$claims"
  classify "$snap" "$claims" "$MIN_AGE" "$$" > "$tmp/found"
  log_rotate
  roots=$(awk -F'\t' '$1 == "root"' "$tmp/found")
  printf 'fm-host-janitor %s (min age %ss)\n' "$MODE" "$MIN_AGE"
  if [ -n "$roots" ]; then
    printf '%-8s %-7s %-17s %-10s %s\n' PID AGE_H CLASS REASON COMMAND
    while IFS=$'\t' read -r _ pid agev klass reason cmd; do
      count=$((count + 1))
      pids=$(awk -F'\t' -v r="$pid" '$1 == "desc" && $3 == r { print $2 }' "$tmp/found")
      # Show the executable by name so the arguments that identify it fit.
      first=${cmd%% *}
      printf '%-8s %-7s %-17s %-10s %s\n' "$pid" "$((agev / 3600))" "$klass" "$reason" \
        "$(printf '%s' "${first##*/}${cmd#"$first"}" | cut -c1-140)"
      [ -z "$pids" ] || printf '         +%s descendant(s): %s\n' \
        "$(printf '%s\n' "$pids" | grep -c .)" "$(printf '%s' "$pids" | tr '\n' ' ')"
      log_line "$klass" "$pid" "$agev" "$reason" "$cmd"
      if [ "$MODE" = apply ]; then
        # shellcheck disable=SC2086 # validated digit pids
        fm_task_proc_terminate "fm-host-janitor" "$GRACE" "$pid" $pids 2>&1 \
          | while IFS= read -r line; do
              printf '  %s\n' "$line"
              log_line signal "$pid" "$agev" "$line" ""
            done
      fi
    done <<EOF
$roots
EOF
  fi
  while IFS=$'\t' read -r udid agev; do
    [ -n "$udid" ] || continue
    sims=$((sims + 1))
    printf 'simulator %s booted %sh, idle\n' "$udid" "$((agev / 3600))"
    log_line simulator "$udid" "$agev" idle ""
    if [ "$MODE" = apply ]; then
      fm_task_proc_sim_shutdown fm-host-janitor "$udid" 2>&1 | sed 's/^/  /'
    fi
  done <<EOF
$(idle_simulators "$snap" "$claims" "$MIN_AGE")
EOF
  printf 'leftover process chains: %s; idle simulators: %s\n' "$count" "$sims"
  log_line summary - - "processes=$count simulators=$sims" ""
  rm -rf "$tmp"
  return 0
}

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

do_install() {
  local home uid
  [ "$(uname)" = Darwin ] || { echo "fm-host-janitor: --install supports macOS launchd only" >&2; return 1; }
  home=$(cd "$FM_HOME" && pwd -P) || { echo "fm-host-janitor: cannot resolve FM_HOME $FM_HOME" >&2; return 1; }
  uid=$(id -u)
  mkdir -p "$(dirname "$PLIST")" || return 1
  cat > "$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$SCRIPT_DIR/fm-host-janitor.sh")</string>
    <string>--apply</string>
    <string>--min-age-hours</string>
    <string>$MIN_AGE_HOURS</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key><string>$(xml_escape "$home")</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
  mv -f -- "$PLIST.tmp" "$PLIST" || return 1
  launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$uid" "$PLIST" || { echo "fm-host-janitor: launchctl bootstrap failed for $PLIST" >&2; return 1; }
  printf 'installed: %s (hourly --apply, min age %sh, log %s)\n' "$PLIST" "$MIN_AGE_HOURS" "$LOG"
}

do_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f -- "$PLIST"
  printf 'uninstalled: %s\n' "$LABEL"
}

do_status() {
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    printf 'loaded: %s (%s)\n' "$LABEL" "$PLIST"
  else
    printf 'not loaded: %s\n' "$LABEL"
  fi
}

case "$ACTION" in
  scan) do_scan ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
