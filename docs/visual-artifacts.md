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
      "push_to_screenote": true,
      "screenote_url": null
    }
  ]
}
```

Capture is fail-soft. If the app cannot boot, a command cannot be driven, or a
capture tool is missing, the agent writes `status: "failed"` with a short reason
and still completes the stage. Pure backend/refactor/docs tasks write
`status: "skipped"` instead.

## Init and doctor readiness

Interactive `hive init` offers two optional visual-artifact setup steps after
the final confirmation and before project files are written:

- install missing baseline capture tools (`ffmpeg` and `asciinema`) through a
  detected package manager, or print the exact command to run manually;
- connect screenote by opening the token settings page, validating a pasted API
  token with an authenticated REST request, and saving it only to the global
  Hive config.

Every prompt defaults to skip. Non-TTY init skips these prompts silently.
`hive doctor` reports the same readiness later as warning rows; missing visual
artifact prerequisites never make doctor fail.

## screenote

After the agent completes, Hive uploads PNG/JPEG stills with
`push_to_screenote: true` and writes the returned hosted URL back into
`screenote_url`. The agent never receives the token.

Configure screenote in the global config or through environment variables:

```yaml
screenote:
  base_url: https://screenote.example
  api_token: null
```

Environment overrides:

```sh
export HIVE_SCREENOTE_BASE_URL=https://screenote.example
export HIVE_SCREENOTE_API_TOKEN=...
```

Blank or missing tokens disable the upload; committed PNG/GIF files still render
in hivebox.

## Capture tools

Baseline tools that `hive init` and `hive doctor` understand:

- `ffmpeg`
- `asciinema`

Additional tools may still be needed where artifacts agents run:

- UI/browser: agent-browser or Playwright with a browser installed.
- TUI/CLI: `vhs` (records straight to GIF), or `asciinema` to record a `.cast`
  plus `agg` to render that `.cast` to a GIF. `ffmpeg` cannot read an asciinema
  `.cast`, so it is not a GIF encoder for terminal recordings on its own.

The hivebox Docker image includes `asciinema` and `ffmpeg` but no terminal-GIF
encoder (`agg`/`vhs`), so an in-box TUI/CLI demo records a `.cast` and then
writes a `failed` capture unless the agent installs `agg` or `vhs`. Browser
capture tools also vary by project and agent environment; a missing tool
records a failed capture rather than failing the pipeline.
