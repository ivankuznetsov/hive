# Escalations for pass 02

## Round 1

### Q1. How should the mandatory live production gates be completed before v0.1.0 is declared release-ready: provide access to an allowlisted GitHub/Telegram test setup and clean Ubuntu host, or keep the package explicitly not release-ready until an operator supplies redacted evidence?
Source: codex-ce-code-review-02.md
Finding: Authenticated GitHub, allowlisted Telegram, clean Ubuntu, and remaining independent-review evidence is incomplete.
Context checked: Plan R12, U6, Verification Contract, and Definition of Done; brainstorm A9; task.md; `wiki/log.d/20260716-prdigest-v0-1-0.md`; available credential environment.
Why not auto-fixable: No GitHub or Telegram credentials or clean Ubuntu target are available, and these checks require operator-controlled external access.
Suggested default: Keep v0.1.0 unpublished and explicitly not release-ready; have the operator run the documented gates and retain only redacted pass/fail metadata.
### A1.
