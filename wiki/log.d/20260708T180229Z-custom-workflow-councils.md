## [2026-07-08T18:02:29Z] workflows - native councils and active terminal stages

**Action:** Added native custom-workflow support for per-stage `agent` /
`model` / `effort`, `kind: council`, and active terminal agent/council stages.
Descriptor parsing now validates council reviewers, quorum, max rounds, exit
rules, optional revise agents, and terminal `deliverable:` aliases. The generic
agent runner honors descriptor-level profile/model overrides, while the new
`Hive::Stages::Council` runner reviews document artifacts with per-reviewer
outputs, deterministic triage files, quorum gating, optional revise loops, and
generic `WAITING` / `COMPLETE` markers. Terminal active stages classify as
archived only when the marker is complete and the deliverable file is non-empty.

**Templates/tests:** Added the `architecture` workflow template
(`inbox -> draft -> review(council) -> architecture(agent-terminal)`) plus
unit coverage for parser/status/resolver/council behavior and an integration
test that drives the architecture workflow end-to-end with deterministic agent
stubs.
