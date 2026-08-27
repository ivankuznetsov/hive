# Opt-in strict benchmark execution

- Added `require_successful_execution: true` as an opt-in campaign contract.
- Strict campaigns rerun nonterminal cells instead of treating preserved patches
  as bought generation evidence.
- Generate and judge independently reject any strict-campaign cell whose
  `run_status` is not `generated` or `empty_diff`.
- Existing campaigns retain paid-patch handoff behavior by default.
