## [2026-07-12T20:20:00Z] agent/daemon — honor complete provider reset dates

**Action:** A live Codex quota wall said `try again at Jul 18th, 2026 7:50 AM`,
but every `limits_reached` writer discarded that text and stamped the fixed
one-hour cooldown. The daemon consequently spent all three bounded retries in
three hours and parked the task days before the real reset. `Hive::AgentLimit`
now conservatively parses only complete dated reset hints (month, day, year,
and time), adds a one-minute boundary grace, rejects expired or more-than-one-
year dates, and otherwise retains the fixed cooldown. Agent, Claude launcher,
execute, CI, triage, and fix marker writers forward their captured provider
text into the helper. Live tmux detection passes only the matched limit menu
and its adjacent reset lines, so unrelated dated transcript prose cannot forge
a hold. When every reviewer is limited, Hive waits for the latest captured
provider boundary rather than whichever reviewer happened to run first. Added
parser, headless-agent, launcher, reviewer, and execute-stage regression
coverage for the exact Codex shape and multiline Claude menu path.
