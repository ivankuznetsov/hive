# Managed browser redirects stay on the issued origin

**Problem:** Live Pi evidence production started Webmail's Rails server on the
controller-issued loopback port, but the application's setup gate emitted an
absolute redirect to that loopback host. `agent-browser` correctly rejected
the redirect because its domain allowlist contains only Hive's random
`.invalid` capture origin, leaving a retained screenshot of the filter's
`Blocked` page instead of the application.

**Change:** The capture proxy now parses the bounded upstream response header
and rewrites a `Location` only when it points to the exact controller-issued
`http://127.0.0.1:<app-port>` endpoint. The path, query, and fragment are
preserved under the random capture origin. Relative redirects and every
foreign host or port remain untouched, and the upstream continues to receive
the loopback `Host` required by development host allowlists.

A focused proxy regression test covers the translation while the existing
wrong-origin and WebSocket tests retain the network-boundary guarantees.

See [[stages/artifacts]].
