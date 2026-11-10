---
date: 2026-11-10
type: ci
---

The install-smoke "Arch dry run" job now runs a full `pacman -Syu --needed` instead of the partial `pacman -Sy`. Arch does not support partial upgrades. During the openssl 4.1 transition, `-Sy <pkgs>` pulled in openssl 4.1 against an image whose pacman, libarchive and other packages still needed `libcrypto.so=3`. The transaction failed, and every branch went red. The other Arch workflows (install-verify, release) already used `-Syu`.
