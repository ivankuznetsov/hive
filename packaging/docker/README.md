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

Terminate TLS at a reverse proxy or tunnel such as Caddy, Cloudflare Tunnel, or
Tailscale. hivebox serves plain HTTP inside the container.

`docker exec` plus `tmux` remains available for emergency shell access, but the
supported operator surface is the authenticated web UI.
