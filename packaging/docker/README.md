# hivebox Docker

Build and run locally:

```sh
docker build -f packaging/docker/Dockerfile -t hivebox .
docker run --rm -p 4567:4567 -v "$PWD/hivebox-data:/data" hivebox
```

`/data` is the box. It contains `$HOME`, Hive config/state/cache, agent auth
directories, cloned repos under `/data/repos`, logs, and the generated web
session secret. Recreate the container against the same bind mount to keep
agent logins and project state.

Sign-in uses the GitHub OAuth **device flow**: set `web.github.owner` (your
GitHub login) in the bind-mounted `config.yml`, click "Continue with GitHub",
and enter the shown code at github.com/login/device from any browser. There is
no callback URL and no client secret to configure; the default
`web.github.client_id` is the shared hivebox OAuth app, overridable with your
own device-flow-enabled app.

Terminate TLS at a reverse proxy or tunnel such as Caddy, Cloudflare Tunnel, or
Tailscale. hivebox serves plain HTTP inside the container.

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
