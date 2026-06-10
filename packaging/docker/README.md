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

`docker exec` plus `tmux` remains available for emergency shell access, but the
supported operator surface is the authenticated web UI.
