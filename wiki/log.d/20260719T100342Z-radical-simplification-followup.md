# Radical simplification follow-up

- Derived ready-action command routing from `TaskAction::ACTIONS` so the bot
  and web no longer maintain independent command maps.
- Kept web dispatch narrower by projecting the shared map through the daemon
  queue allowlist; `ready_to_advance` remains an in-process approve action.
- Closed the corresponding Hivebox residual in [[gaps]].
- Made `Hive::Workflow#executable_slots` the shared actor topology for
  configuration, managed validation, and runtime admission.
- Moved redacted mapping/input presentation onto the configuration snapshot and
  made lifecycle resolution consume a single validated package result.
- Reused the shared recursive key normalizer, digest pattern, and mapping-role
  vocabulary instead of maintaining workflow-package copies.
- Hoisted project configuration and temporary runtime admission into the
  workflow command base, and made update reports single-evaluation values.
- Routed task metadata mutations through one field-preserving rewrite and
  generic agent/council marker actions through their shared stage base.
- Reused one immutable managed runtime context across each actor's prompt and
  permission setup, and stopped creating empty actor-policy directories.
- Made task capture resolve managed selection once, loading project config only
  when a legacy lock actually needs its compatibility snapshot.
- Kept managed context failures inside the permission-error marker boundary,
  reused the remaining exact helpers, and corrected actor-policy documentation.
