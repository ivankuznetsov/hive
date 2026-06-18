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

Recommended tools where artifacts agents run:

- UI/browser: agent-browser or Playwright with a browser installed.
- TUI/CLI: asciinema or vhs plus ffmpeg for GIF output.

The hivebox Docker image includes `asciinema` and `ffmpeg`. Browser capture
tools can still vary by project and agent environment; absence records a
failed capture rather than failing the pipeline.
