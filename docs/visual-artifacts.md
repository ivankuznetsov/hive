# Outcome evidence

`7-artifacts` completes only after Hive publishes an identity-bound evidence
package and an independent reviewer accepts every user-visible outcome claim.
Legacy files under `<task>/media/` remain visible as diagnostics, but they do
not establish completion.

## Choose the smallest truthful proof

- `screenshot`: one stable web/interface state, including one coherent change
  shown on multiple screens.
- `video`: a flow, transition, timing, or ordering change. A montage or two
  screenshots does not replace temporal video.
- `terminal`: CLI or TUI behavior, retained as an asciinema v2-compatible cast
  plus bounded plain text.
- `document`: an invisible refactor or backend contract, explained with a
  concrete schema, architecture description, Markdown, JSON, text, or static
  image grounded in the frozen diff.

The inference role selects among these kinds from the task intent and exact
committed diff. Controller code validates structure, containment, hashes, media
decoding, secret-shaped content, and changed-path traceability; the independent
reviewer decides whether the evidence actually proves the claim.

## One shipped capture stack

Hive resolves capture capabilities before starting the producer:

- Web capture uses Hive's exact pinned native `agent-browser` CLI and managed
  Chrome through `hive evidence browser`. The producer receives one
  controller-issued command prefix rooted in its writable evidence attempt;
  the raw browser socket is never exposed. It can reach one random `.invalid` origin
  mapped by Hive to one issued loopback application port. Producers do not
  select Firefox, Playwright, Puppeteer, or another browser stack. Hive starts
  and verifies the session before the producer runs. Its gateway admits a
  closed interaction vocabulary, checks navigation origin, captures media to a
  controller-private staging path, and exclusively publishes only safe
  basename `.png`/`.webm` files into the attempt root.
- Terminal capture uses `hive evidence terminal NAME -- COMMAND...`, Hive's
  Ruby PTY recorder. It invokes the command without a shell, emits `.cast` and
  `.txt` files, reaps the descendant process tree, and rejects escaped children.
- `ffmpeg`, `ffprobe`, and Tesseract decode and inspect retained visual media.
  Hive derives the bounded video storyboard used for semantic review; the
  producer does not fabricate one.

Missing required capability publishes a recoverable semantic blocker before
production. Hive closes the named browser session and removes the raw attempt
workspace, application server, proxy, and producer process group after custody
transfer.

Playwright remains a development dependency for Rails system tests and manual
demo scripts. It is not an outcome-evidence capture interface. Screenote and
legacy Hivebox media remain optional diagnostics and are never completion
authority.

For the ledger, retry, recovery, and reviewer contracts, see
`wiki/stages/artifacts.md` and `wiki/commands/evidence.md`.
