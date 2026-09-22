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

: > "$state/.secondmate-melt-cooldown-mate"
FM_SECONDMATE_MELT_COOLDOWN_SECS=3600
fm_secondmate_melt_cooldown_active "$state" mate \
  || fail "a fresh cooldown marker did not suppress relaunch"
FM_SECONDMATE_MELT_COOLDOWN_SECS=0
! fm_secondmate_melt_cooldown_active "$state" mate \
  || fail "the documented zero-second test override did not expire the cooldown"
pass "the per-mate cooldown prevents relaunch thrash"
