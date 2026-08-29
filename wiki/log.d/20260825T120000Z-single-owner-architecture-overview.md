## Architecture overview defers subsystem detail to one owner page

- Collapsed the duplicated admission narratives in `wiki/architecture.md`
  ("Process model" + "Dispatch flow") into one relationship statement plus a
  single routing diagram that defers to [[modules/attempts]] and
  [[modules/daemon]].
- Moved overview-only facts to their owner pages: loss healing never projects
  a recovery marker and the host-local no-event-bus durability stance now
  live on [[modules/attempts]].
- Removed the workspace projection's negative-guarantee list from the
  overview; the unified guarantee list (no `Commands::Status` entry, no fleet
  or global-attempt-store scans, no GitHub reads, no owned mutation) now lives
  only on [[modules/task_workspace]].
- Updated `wiki/modules/daemon.md` and `wiki/modules/bot.md` cross-references
  from §"Dispatch flow" to §"Process model"; refreshed `updated:` frontmatter.
