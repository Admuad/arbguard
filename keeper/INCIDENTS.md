# Keeper incidents

Human-readable companion to `decisions.log`. The bot does not write
this file; the operator does — one section per incident:

```markdown
## 2026-11-20 — T1 hour-use 84%, policy 0
- Rule / numbers: ...
- Action taken: ...
- Outcome: ...
```

No incidents recorded yet. The bot has only ever logged `NO_ACTION`
on live Sepolia (dry-run, 20 Nov 2026) and `WOULD_THROTTLE` /
`THROTTLE_SENT` in the local-Anvil fork test.
