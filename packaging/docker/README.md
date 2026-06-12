# hivebox Docker

## Install (golden path)

One command on any machine with Docker.

macOS / Linux (and Windows inside a WSL 2 shell):

```sh
curl -fsSL https://hivecli.sh/box | sh
```

Windows PowerShell:

```powershell
irm https://hivecli.sh/box.ps1 | iex
```

(the scripts are `packaging/docker/install-box.{sh,ps1}`; they pull
`ghcr.io/ivankuznetsov/hivebox:latest`, start the container with a
persistent `~/hivebox-data` mount, and print the URL — the image is
multi-arch, so Apple-silicon Macs and ARM home servers pull native). Then open
http://localhost:4567 and click **Continue with GitHub** — you'll type a
short code at github.com/login/device from any browser or phone. **The
first sign-in claims the box as its owner**; every later login by anyone
else is refused. No OAuth app, no client secret, no config files.

First-run checklist, all in the UI: connect Claude (and Codex) on the
Agents page, connect **gh** there too (it supplies git push credentials
for the daemon), optionally connect Telegram, then add your first
repository on the Repos page.

Build and run from source instead:

```sh
docker build -f packaging/docker/Dockerfile -t hivebox .
docker run --rm -p 127.0.0.1:4567:4567 -v "$PWD/hivebox-data:/data" hivebox
```

The loopback bind is deliberate: until the box is claimed, the first GitHub
login becomes its owner — don't publish it beyond localhost unless ownership
is pre-pinned (`web.github.owner`) or a trusted proxy/tunnel fronts it.

`/data` is the box. It contains `$HOME`, Hive config/state/cache, agent auth
directories, cloned repos under `/data/repos`, logs, and the generated web
session secret. Recreate the container against the same bind mount to keep
agent logins, ownership, and project state.

Sign-in uses the GitHub OAuth **device flow** — no callback URL and no client
secret; the default `web.github.client_id` is the shared hivebox OAuth app,
overridable with your own device-flow-enabled app. To pre-pin ownership
instead of first-login claiming, set `web.github.owner` in the bind-mounted
`config.yml`.

## Updating

Each release publishes `ghcr.io/ivankuznetsov/hivebox:<version>` and moves
`:latest`. A running box updates with:

```sh
docker pull ghcr.io/ivankuznetsov/hivebox:latest
docker rm -f hivebox
curl -fsSL https://hivecli.sh/box | sh   # or docker run with your usual flags
```

Everything that matters — ownership, agent logins, repos, pipeline state,
session secret — lives on the `/data` mount and survives the container
swap. Pin `HIVEBOX_IMAGE=ghcr.io/ivankuznetsov/hivebox:<version>` to stay
on an exact version.

Terminate TLS at a reverse proxy or tunnel such as Caddy, Cloudflare Tunnel,
or Tailscale. hivebox serves plain HTTP inside the container, and live
updates work on whatever origin you browse it at (Action Cable accepts
same-origin-as-host; `web.origin` is only needed when origin and host
genuinely differ).

The supported operator surface is the authenticated web UI — a Rails 8 +
Turbo app served by `hive web` inside the container (live status over Turbo
Streams, image-attaching idea composer, your GitHub repo list one click from
registration).

## Terminal access: hive tui and tmux

The image ships `tmux` and the full hive CLI, and `docker exec` inherits the
container's environment (`HOME` and all hive state on `/data`) — so the TUI
and the web UI operate on the same pipeline, and actions taken in one show
up live in the other.

```sh
# Run the TUI interactively (simplest):
docker exec -it <container> hive tui

# Run the TUI inside tmux so it survives disconnects — the same command
# reattaches later (detach with Ctrl-b d, the TUI keeps running):
docker exec -it <container> tmux new -A -s tui hive tui
```

Agent sessions are also reachable: the default project config runs Claude in
`claude_mode=tmux`, so while the daemon executes a stage the live Claude
session runs in a tmux session inside the container. Watch or steer it:

```sh
docker exec -it <container> tmux ls                 # list running agent sessions
docker exec -it <container> tmux attach -t <name>   # attach; Ctrl-b d to detach
```

`tmux ls` reporting "no server running" just means no agent is mid-run and no
tmux session has been started yet.
