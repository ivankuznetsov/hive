#!/usr/bin/env bash
# Builds the hive-bench-runner image with REAL hive baked in (hive-bench v2).
#
# The runner drives actual hive stages, so the image bakes a PINNED snapshot of
# the hive tool: a clean `git archive HEAD` of the hive repo, copied into the
# build context and `gem install`ed (see Dockerfile.runner). HIVE_SRC points at
# the hive checkout to pin (default ~/Dev/hive).
#
#   HIVE_SRC=~/Dev/hive harness/build_runner.sh
set -euo pipefail

HIVE_SRC="${HIVE_SRC:-$HOME/Dev/hive}"
cd "$(dirname "$0")/.."

[ -e "$HIVE_SRC/.git" ] || { echo "HIVE_SRC=$HIVE_SRC is not a git checkout" >&2; exit 1; }
rev="$(git -C "$HIVE_SRC" rev-parse --short HEAD)"
echo "pinning hive tool from $HIVE_SRC @ $rev"

# Clean source only (no vendor/bundle, .hive-state, worktrees) — see .dockerignore.
git -C "$HIVE_SRC" archive --format=tar HEAD >hive-src.tar
trap 'rm -f hive-src.tar' EXIT

IMAGE_TAG="${IMAGE_TAG:-hive-bench-runner:latest}"
docker build -f Dockerfile.runner -t "$IMAGE_TAG" ${IMAGE_BUILD_ARGS:-} .
echo "built $IMAGE_TAG with hive tool @ $rev"
