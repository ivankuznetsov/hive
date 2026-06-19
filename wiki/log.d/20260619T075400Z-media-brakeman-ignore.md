---
date: 2026-06-19
slug: media-brakeman-ignore
pages: [testing, gaps]
---

During PR #515 babysitting, the rebased branch cleared Git conflicts and then
CI exposed a Brakeman weak `SendFile` warning for
`TasksController#media`. The route and controller already constrain the
filesystem boundary: `:filename` is route-limited to PNG/JPEG/GIF names,
`resolved_media_path` applies `File.basename`, repeats the extension check,
resolves the real task folder and `media/` directory, refuses a symlinked media
root, and only streams files whose realpath remains below that media root.

Added the current Brakeman fingerprint to `config/brakeman.ignore` with that
rationale, added an integration regression for a symlinked `media/` directory,
and refreshed [[testing]] / [[gaps]] to include the media-route false-positive
policy. Verified:

```bash
bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```
