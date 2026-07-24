# Proxy host login gate

- Removed the production hostname allowlist that returned Rails 403 responses
  for unconfigured VPN, tunnel, and reverse-proxy names.
- Restricted native no-auth access to requests whose socket peer and normalized
  Host are both loopback; every other hostname now reaches the existing GitHub
  device-flow owner gate.
- Kept the policy vendor-neutral: `HIVE_WEB_ORIGIN` remains an optional extra
  Action Cable origin rather than an HTTP Host authorization setting.
- Added production middleware and controller regressions for arbitrary proxy
  hosts, login redirects, and mutation refusal before side effects.
- Hardened the bypass against spoofed `X-Forwarded-Host`, normalized bracketed
  IPv6 Host authorities, and made proxied native login disclose first-owner
  claiming instead of presenting GitHub as an optional repository connection.
