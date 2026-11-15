# Preserve agent launch dependencies in managed services

The shared service installer discovers agent and interpreter directories
independently of Ruby, and preserves explicit agent binary overrides for
systemd and launchd. This fixes babysitter Codex ENOENT when Codex is available
only through the operator's tool-manager PATH. Daemon, bot, and web use the
same rendering. Tests execute version-only fake agents under rendered service
environments and cover separate Node directories, path escaping, stable
symlinks, override validation, and excluded shell credentials. Existing
installations use the backed-up `install --force` lifecycle.
