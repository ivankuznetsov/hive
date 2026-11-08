---
title: Select the installed OpenCode launcher in component release checks
date: 2026-09-16
---

The agent-cli-runtime release workflow explicitly passes the npm-installed
OpenCode executable to the offline contract smoke. Automatic discovery excludes
package-manager launchers to avoid modifying a developer's installation; the
release runner owns its pinned npm installation and can select it explicitly.

The pinned CLI is checked against a route present in its bundled offline model
inventory, rather than a newer route available only after a catalog refresh.
