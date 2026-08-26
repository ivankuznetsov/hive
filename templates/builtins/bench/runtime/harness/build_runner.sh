#!/usr/bin/env bash
# Builds the hive-bench-runner image with REAL hive baked in (hive-bench v2).
#
# The runner drives actual hive stages, so the image bakes a PINNED snapshot of
# the hive tool: a clean `git archive HEAD` of the hive repo, copied into the
# build context and `gem install`ed (see Dockerfile.runner). HIVE_SRC points at
# the hive checkout to pin (default ~/Dev/hive).
#
#   HIVE_SRC=~/Dev/hive harness/build_runner.sh
#
# The image contains both Pi and OpenCode, but the harness keeps a distinct
# OpenCode tag so agent-specific runner selection remains explicit. Override
# either tag independently with IMAGE_TAG / OPENCODE_IMAGE_TAG.
set -euo pipefail

HIVE_SRC="${HIVE_SRC:-$HOME/Dev/hive}"
cd "$(dirname "$0")/.."

[ -e "$HIVE_SRC/.git" ] || { echo "HIVE_SRC=$HIVE_SRC is not a git checkout" >&2; exit 1; }
full_rev="$(git -C "$HIVE_SRC" rev-parse HEAD)"
short_rev="$(git -C "$HIVE_SRC" rev-parse --short HEAD)"
echo "pinning hive tool from $HIVE_SRC @ $short_rev"

# Clean source only (no vendor/bundle, .hive-state, worktrees) — see .dockerignore.
git -C "$HIVE_SRC" archive --format=tar HEAD >hive-src.tar
trap 'rm -f hive-src.tar' EXIT

IMAGE_TAG="${IMAGE_TAG:-hive-bench-runner:latest}"
OPENCODE_IMAGE_TAG="${OPENCODE_IMAGE_TAG:-hive-bench-runner:opencode}"
read -r -a image_build_args <<< "${IMAGE_BUILD_ARGS:-}"
image_tag_args=(-t "$IMAGE_TAG")
if [ -n "$OPENCODE_IMAGE_TAG" ] && [ "$OPENCODE_IMAGE_TAG" != "$IMAGE_TAG" ]; then
  image_tag_args+=(-t "$OPENCODE_IMAGE_TAG")
fi
docker build -f Dockerfile.runner --build-arg "HIVE_BUILD_SHA=$full_rev" \
  "${image_tag_args[@]}" "${image_build_args[@]}" .
echo "built ${IMAGE_TAG}${OPENCODE_IMAGE_TAG:+ and ${OPENCODE_IMAGE_TAG}} with hive tool @ $short_rev"
