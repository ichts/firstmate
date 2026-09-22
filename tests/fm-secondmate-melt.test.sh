#!/usr/bin/env bash
# Portable contract tests for secondmate commander-model melt decisions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-melt-lib.sh
. "$ROOT/bin/fm-secondmate-melt-lib.sh"

case_dir=$(fm_test_tmproot fm-secondmate-melt)
config="$case_dir/config"
state="$case_dir/state"
mkdir -p "$config" "$state"

quota='{
  "schemaVersion": 6,
  "providers": [
    {
      "provider": "pi",
      "accountKey": "zai-coding-cn",
      "quotaSemantics": {"status":"known","effectiveAvailability":[
        {"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}
      ]}
    },
    {
      "provider": "pi",
      "accountKey": "default",
      "quotaSemantics": {"status":"unknown","effectiveAvailability":[]}
    },
    {
      "provider": "pi",
      "accountKey": "openai-codex",
      "quotaSemantics": {"status":"known","effectiveAvailability":[
        {"scope":"all_models","status":"known","effectivePercentRemaining":72,"runway":{"status":"through_reset"}}
      ]}
    },
    {
      "provider": "codex",
      "accountKey": "codex-home",
      "quotaSemantics": {"status":"known","effectiveAvailability":[
        {"scope":"all_models","status":"known","effectivePercentRemaining":72,"runway":{"status":"through_reset"}}
      ]}
    }
  ]
}'

[ "$(fm_secondmate_melt_quota_status "$quota" pi zai-coding-cn/glm-5.3)" = dead ] \
  || fail "the exhausted current model was not classified dead"
[ "$(fm_secondmate_melt_quota_status "$quota" pi unknown/model)" = unknown ] \
  || fail "an unmeasured model was treated as quota-ok"
[ "$(fm_secondmate_melt_quota_status "$quota" codex gpt-5.6-luna codex)" = ok ] \
  || fail "a measured runnable replacement was not classified quota-ok"
pass "quota status separates dead, unknown, and runnable models"

printf '%s\n' 'pi openai-codex/gpt-5.6-luna max' > "$config/secondmate-harness"
printf '%s\n' '{"default":{"harness":"codex","model":"gpt-5.6-luna","effort":"max","provider":"codex"}}' \
  > "$config/crew-dispatch.json"
profile=$(fm_secondmate_melt_choose_profile "$quota" "$config" "$ROOT/bin" pi zai-coding-cn/glm-5.3) \
  || fail "a quota-ok parent pin was not selected"
[ "$profile" = $'pi\topenai-codex/gpt-5.6-luna\tmax\tparent-pin' ] \
  || fail "the parent pin did not take precedence: $profile"
pass "a quota-ok explicit parent pin wins"

printf '%s\n' 'pi zai-coding-cn/glm-5.3 high' > "$config/secondmate-harness"
cat > "$config/crew-dispatch.json" <<'JSON'
{"default":[
  {"harness":"codex","model":"gpt-5.6-sol","effort":"medium","provider":"codex"},
  {"harness":"pi","model":"zai-coding-cn/glm-5.3","effort":"high","provider":"pi"},
  {"harness":"codex","model":"gpt-5.6-luna","effort":"max","provider":"codex"}
]}
JSON
profile=$(fm_secondmate_melt_choose_profile "$quota" "$config" "$ROOT/bin" pi zai-coding-cn/glm-5.3) \
  || fail "the runnable crew-dispatch fallback was not selected"
[ "$profile" = $'codex\tgpt-5.6-luna\tmax\tcrew-dispatch-default' ] \
  || fail "the decision did not skip Sol and exhausted GLM: $profile"
pass "fallback skips Sol and quota-dead GLM, then selects explicit Luna"

printf '%s\n' '{"default":{"harness":"codex","effort":"max","provider":"codex"}}' \
  > "$config/crew-dispatch.json"
! fm_secondmate_melt_choose_profile "$quota" "$config" "$ROOT/bin" pi zai-coding-cn/glm-5.3 >/dev/null \
  || fail "a replacement without an explicit model was accepted"
pass "replacement profiles require an explicit model"

FM_SECONDMATE_MELT_EVIDENCE_COUNT=2
! fm_secondmate_melt_record_evidence "$state" mate glm-5.3 'attempt 1 failed: 429 quota exceeded' >/dev/null \
  || fail "one pane observation reached the repeated-evidence threshold"
! fm_secondmate_melt_record_evidence "$state" mate glm-5.3 'attempt 1 failed: 429 quota exceeded' >/dev/null \
  || fail "re-reading one stale error screen incremented pane evidence"
[ "$(fm_secondmate_melt_record_evidence "$state" mate glm-5.3 'attempt 2 failed: 429 quota exceeded')" = 2 ] \
  || fail "two distinct pane observations did not reach the evidence threshold"
! fm_secondmate_melt_record_evidence "$state" mate glm-5.3 'ready for input' >/dev/null \
  || fail "a healthy observation retained dead-model evidence"
pass "pane evidence requires distinct errors and resets on a healthy observation"

FM_SECONDMATE_MELT_COOLDOWN_SECS=3600
fm_secondmate_melt_cooldown_write "$state" mate codex gpt-5.6-luna \
  || fail "the cooldown marker for the replacement profile could not be written"
fm_secondmate_melt_cooldown_active "$state" mate codex gpt-5.6-luna \
  || fail "a fresh replacement cooldown did not suppress relaunch for that profile"
! fm_secondmate_melt_cooldown_active "$state" mate pi zai-coding-cn/glm-5.3 \
  || fail "a restored dead pin stayed suppressed by the replacement cooldown"
: > "$state/.secondmate-melt-cooldown-mate"
! fm_secondmate_melt_cooldown_active "$state" mate codex gpt-5.6-luna \
  || fail "a bare legacy cooldown marker suppressed melt evaluation"
FM_SECONDMATE_MELT_COOLDOWN_SECS=0
fm_secondmate_melt_cooldown_write "$state" mate codex gpt-5.6-luna \
  || fail "the zero-second cooldown marker could not be rewritten"
! fm_secondmate_melt_cooldown_active "$state" mate codex gpt-5.6-luna \
  || fail "the documented zero-second test override did not expire the cooldown"
pass "cooldown is bound to the live harness/model and expires on override"

watch_home=$(fm_test_tmproot fm-secondmate-melt-watch)
mkdir -p "$watch_home/state" "$watch_home/config" "$watch_home/bin"
printf '%s\n' 'pi zai-coding-cn/glm-5.3 high' > "$watch_home/config/secondmate-harness"
cat > "$watch_home/config/crew-dispatch.json" <<'JSON'
{"default":[]}
JSON
printf '%s\n' \
  'kind=secondmate' \
  'harness=pi' \
  'model=zai-coding-cn/glm-5.3' \
  'effort=high' \
  'provider=pi' \
  > "$watch_home/state/mate.meta"
printf '%s\n' "$quota" > "$watch_home/state/quota.json"
cat > "$watch_home/bin/fm-control.sh" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected relaunch after a terminal melt path\n' >&2
exit 97
EOF
chmod +x "$watch_home/bin/fm-control.sh"
FM_SECONDMATE_MELT_COOLDOWN_SECS=3600
export FM_SECONDMATE_MELT_COOLDOWN_SECS
(
  FM_HOME="$watch_home"
  FM_STATE_OVERRIDE="$watch_home/state"
  FM_CONFIG_OVERRIDE="$watch_home/config"
  FM_ROOT_OVERRIDE="$ROOT"
  FM_SECONDMATE_QUOTA_SNAPSHOT="$watch_home/state/quota.json"
  FM_SECONDMATE_MELT_COOLDOWN_SECS=3600
  export FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_SECONDMATE_QUOTA_SNAPSHOT FM_SECONDMATE_MELT_COOLDOWN_SECS
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  SCRIPT_DIR="$watch_home/bin"
  PATH="$watch_home/bin:$PATH"
  export PATH
  wakes=0
  fm_wake_append() { printf '%s\n' "$3" >> "$watch_home/state/wake.log"; }
  wake() { wakes=$((wakes + 1)); printf '%s\n' "$1" >> "$watch_home/state/wake-calls.log"; }
  secondmate_health_model_melt mate "$watch_home/state/mate.meta" "$(cat "$watch_home/state/quota.json")" 'ready' \
    || exit 11
  [ "$wakes" -eq 1 ] || exit 12
  grep -F 'new=none' "$watch_home/state/wake-calls.log" >/dev/null || exit 13
  fm_secondmate_melt_cooldown_active "$watch_home/state" mate pi zai-coding-cn/glm-5.3 || exit 14
) || fail "a no-replacement melt path fell through or skipped the dead-model cooldown"
pass "no-replacement melt is terminal and cools only the live dead pin"

(
  FM_HOME="$watch_home"
  FM_STATE_OVERRIDE="$watch_home/state"
  FM_CONFIG_OVERRIDE="$watch_home/config"
  FM_ROOT_OVERRIDE="$ROOT"
  export FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  SECONDMATE_HEALTH_INTERVAL_SECS=0
  rm -f "$watch_home/state/.secondmate-health-last"
  secondmate_health_inbox_alarm() { return 7; }
  secondmate_health_model_melt() { return 0; }
  if secondmate_health_tick; then
    exit 21
  fi
) || fail "secondmate_health_tick swallowed an inbox gate bookkeeping failure"
(
  FM_HOME="$watch_home"
  FM_STATE_OVERRIDE="$watch_home/state"
  FM_CONFIG_OVERRIDE="$watch_home/config"
  FM_ROOT_OVERRIDE="$ROOT"
  export FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  SECONDMATE_HEALTH_INTERVAL_SECS=0
  rm -f "$watch_home/state/.secondmate-health-last"
  secondmate_health_inbox_alarm() { return 0; }
  secondmate_health_capture() { printf 'pane\n'; }
  secondmate_health_model_melt() { return 9; }
  if secondmate_health_tick; then
    exit 23
  fi
) || fail "secondmate_health_tick swallowed a melt gate bookkeeping failure"
pass "health tick fails closed on inbox and melt bookkeeping errors"

printf '%s\n' \
  'kind=secondmate' \
  'harness=pi' \
  'model=zai-coding-cn/glm-5.3' \
  'effort=high' \
  'provider=pi' \
  > "$watch_home/state/mate.meta"
rm -f "$watch_home/state/.secondmate-melt-cooldown-mate" \
  "$watch_home/state/.secondmate-melt-evidence-mate" \
  "$watch_home/state/success-wake.log" \
  "$watch_home/state/success-wake-calls.log" \
  "$watch_home/state/relaunch.log"
cat > "$watch_home/config/crew-dispatch.json" <<'JSON'
{"default":[{"harness":"codex","model":"gpt-5.6-luna","effort":"max","provider":"codex"}]}
JSON
cat > "$watch_home/bin/fm-control.sh" <<'EOF'
#!/usr/bin/env bash
printf 'relaunch ok\n'
exit 0
EOF
chmod +x "$watch_home/bin/fm-control.sh"
(
  FM_HOME="$watch_home"
  FM_STATE_OVERRIDE="$watch_home/state"
  FM_CONFIG_OVERRIDE="$watch_home/config"
  FM_ROOT_OVERRIDE="$ROOT"
  FM_SECONDMATE_MELT_COOLDOWN_SECS=3600
  export FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_SECONDMATE_MELT_COOLDOWN_SECS
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  SCRIPT_DIR="$watch_home/bin"
  PATH="$watch_home/bin:$PATH"
  export PATH
  fm_wake_append() { printf '%s\n' "$3" >> "$watch_home/state/success-wake.log"; }
  wake() { printf '%s\n' "$1" >> "$watch_home/state/success-wake-calls.log"; }
  secondmate_health_model_melt mate "$watch_home/state/mate.meta" "$(cat "$watch_home/state/quota.json")" 'ready' \
    || exit 31
  fm_secondmate_melt_cooldown_active "$watch_home/state" mate codex gpt-5.6-luna || exit 32
  ! fm_secondmate_melt_cooldown_active "$watch_home/state" mate pi zai-coding-cn/glm-5.3 || exit 33
  printf '%s\n' \
    'kind=secondmate' \
    'harness=pi' \
    'model=zai-coding-cn/glm-5.3' \
    'effort=high' \
    'provider=pi' \
    > "$watch_home/state/mate.meta"
  relaunches=0
  cat > "$watch_home/bin/fm-control.sh" <<'INNER'
#!/usr/bin/env bash
echo relaunch-after-restore >> "${FM_STATE_OVERRIDE}/relaunch.log"
printf 'relaunch ok\n'
exit 0
INNER
  chmod +x "$watch_home/bin/fm-control.sh"
  secondmate_health_model_melt mate "$watch_home/state/mate.meta" "$(cat "$watch_home/state/quota.json")" 'ready' \
    || exit 34
  grep -F 'relaunch-after-restore' "$watch_home/state/relaunch.log" >/dev/null || exit 35
) || fail "a restored dead pin stayed silent under the replacement cooldown"
pass "successful melt cools the replacement and remelts a restored dead pin"
