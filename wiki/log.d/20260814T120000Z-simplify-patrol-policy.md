# Simplify Patrol routing and runaway protection

- Architecture Patrol now emits one current v4 contract with explicit `fix`,
  `discuss`, or `dismiss` routes and non-numeric architecture effects.
- The current JobStore starts fresh in v4 and leaves v3 bytes opaque.
- Ordinary and Architecture Patrol now share one high per-agent token fuse and
  a project-wide agent lock; usage remains telemetry instead of daily/cycle
  allowance.
- `hive update` fleet migration removes the retired allowance, multiplier, USD,
  leverage, and threshold config keys before the current runtime loads.
- The canonical component-boundary catalog and native Hive skill describe the
  same v4 authority and route-to-action semantics.
- A fixed 12-slice Architecture review guard prevents empty-result fan-out
  without restoring cycle, daily, launch-count, or USD allowances.
- The project Patrol page reads the v2 job projection and displays current
  `fix` and `discuss` findings without legacy score fields.
- Retired multiline YAML values are removed as complete nodes, and a successful
  fleet migration always performs the single daemon cutover restart so a retry
  cannot lose restart intent from an earlier partial pass.
- Agent and fixer prompts use the categorical route vocabulary; they no longer
  describe Architecture theses with the retired numeric-policy `accepted` term.
