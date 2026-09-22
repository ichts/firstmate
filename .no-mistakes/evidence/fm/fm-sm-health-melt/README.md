# Secondmate health hard-gate evidence

Captain diagnosis (2026-09-22): translateimage secondmate stayed on
`zai-coding-cn/glm-5.3` after GLM Coding Plan weekly/monthly cap (429). Steers
landed in parent-route inbox but sat unhandled because every turn hit 429.
crew-dispatch correctly preferred Luna; the live Pi session model did not.

## What these artifacts prove

1. `captain-scenario-dead-quota-stall.txt` — end-to-end watcher health tick:
   - classifies live GLM pin as quota-dead
   - alarms on 112 unhandled steers (count + age hard gate)
   - skips Sol + dead GLM, melts to `codex/gpt-5.6-luna/max`
   - updates meta + relaunches (no silent stall)

2. `no-replacement-terminal-gate.txt` — when no quota-ok replacement exists:
   - publishes a terminal melt wake
   - cools the dead pin
   - refuses thrash on the next tick

3. `remote-inbox-health-112-steers.txt` — remote control plane measures
   `state/parent-route/<id>.inbox` and reports the backlog breach.

Automated contracts also passed:
- `bash tests/fm-secondmate-melt.test.sh`
- `bash tests/fm-secondmate-inbox.test.sh`
