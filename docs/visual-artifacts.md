# Visual artifacts

The `7-artifacts` stage now asks the artifacts agent to create best-effort
visual proof when a task has an observable UI, TUI, or CLI surface.

Captured media is written under the task folder:

```text
<task>/media/
  manifest.json
  01-home.png
  demo.gif
```

`manifest.json` is the contract between the agent, the Ruby stage, and hivebox:

```json
{
  "schema": 1,
  "status": "captured | skipped | failed",
  "reason": "required when skipped or failed",
  "surface": "ui | tui | none",
  "items": [
    {
      "file": "01-home.png",
      "type": "still",
      "caption": "Home page after load",
      "screenote_url": "https://screenote.ai/...",
      "screenote_skipped_reason": null
    }
  ]
}
```

Capture is fail-soft. If the app cannot boot, a command cannot be driven, or a
capture tool is missing, the agent writes `status: "failed"` with a short reason
and still completes the stage. Pure backend/refactor/docs tasks write
`status: "skipped"` instead.

## screenote

Screenote uploads go through OAuth + MCP, not a stored REST token. Run
`hive connect screenote` once (see [[commands/screenote]] in the wiki for the
full flow); it stores an OAuth credential at `~/.config/hive/screenote.json`
(mode 0600). For a connected Claude-backed `7-artifacts` run, Hive injects an
ephemeral strict MCP config and the agent itself calls the Screenote MCP tool
`create_screenshot_upload`, PUTs the image bytes to the returned signed URL, and
writes the hosted URL into that item's `screenote_url`. When an upload is
skipped or fails, the agent leaves `screenote_url` as `null` and records a
`screenote_skipped_reason`.

Only the Screenote base URL lives in config (or its env override); the OAuth
token is never placed in YAML or the environment:

```yaml
screenote:
  base_url: https://screenote.example
```

```sh
export HIVE_SCREENOTE_BASE_URL=https://screenote.example
```

If the credential is missing, expired, incomplete, or invalid, no MCP server is
injected: the run is fail-soft, committed PNG/GIF files still render in hivebox,
and each still item records a `screenote_skipped_reason`.

## Capture tools

Recommended tools where artifacts agents run:

- UI/browser: agent-browser or Playwright with a browser installed.
- TUI/CLI: `vhs` (records straight to GIF), or `asciinema` to record a `.cast`
  plus `agg` to render that `.cast` to a GIF. `ffmpeg` cannot read an asciinema
  `.cast`, so it is not a GIF encoder for terminal recordings on its own.

The hivebox Docker image includes `asciinema` and `ffmpeg` but no terminal-GIF
encoder (`agg`/`vhs`), so an in-box TUI/CLI demo records a `.cast` and then
writes a `failed` capture unless the agent installs `agg` or `vhs`. Browser
capture tools also vary by project and agent environment; a missing tool
records a failed capture rather than failing the pipeline.
