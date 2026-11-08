---
title: Repair 0.7.3 distribution verification and Hivebox builds
---

The post-release install verifier now models systemd state rather than returning
empty success, preserving force-upgrade and uninstall checks against the actual
installed release. Hivebox installs the browser dependency installer's sudo
prerequisite and skips unavailable Chrome for Testing on Linux ARM64. A manual
recovery workflow builds released source with the corrected image recipe and
promotes only both natively smoked digests, without changing signed artifacts.

The Hivebox entrypoint now initializes fresh runtime storage through the same
current-format installation contract as `hive setup` before starting children.
It validates existing storage and refuses incompatible databases.
