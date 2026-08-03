#!/usr/bin/env bash
# Dev tool — not used by any workflow. Compares the two NMEA 2000 decode paths
# shipped in the image (canboat's C analyzer vs canboatjs) over the canboatjs
# test corpus, and prints a field-level difference report.
#
# Usage: scripts/canboat-parity.sh [image] > report.json
#   image             image to test (default sk:canboat)
#   PARITY_WORKDIR    reuse/keep a working dir (default: mktemp -d, removed on
#                     exit). The canboatjs clone lands here.
#
# The report is the deliverable: differences are information, not a failure.
# Exit is non-zero only if the harness itself could not run.
set -euo pipefail

IMAGE=${1:-sk:canboat}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CLEANUP=""
if [ -z "${PARITY_WORKDIR:-}" ]; then
  PARITY_WORKDIR=$(mktemp -d)
  CLEANUP=$PARITY_WORKDIR
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

# Pin the corpus to the exact canboatjs version the image ships, so the
# comparison never runs new tests against an older decoder.
CBJS_VERSION=$(docker run --rm --entrypoint node "$IMAGE" \
  -p "require('/home/node/signalk/node_modules/@canboat/canboatjs/package.json').version")
echo "image canboatjs version: $CBJS_VERSION" >&2

# A reused workdir may hold a corpus from an older image's canboatjs — that
# would silently compare against the wrong test data, so anything that is not
# a clean checkout of exactly v$CBJS_VERSION is re-cloned.
if [ -d "$PARITY_WORKDIR/canboatjs" ]; then
  have=$(git -C "$PARITY_WORKDIR/canboatjs" describe --tags --exact-match 2>/dev/null || true)
  dirty=$(git -C "$PARITY_WORKDIR/canboatjs" status --porcelain 2>/dev/null | head -1)
  if [ "$have" != "v$CBJS_VERSION" ] || [ -n "$dirty" ]; then
    echo "reused corpus is ${have:-not a git checkout}${dirty:+ (dirty)} — refreshing to v$CBJS_VERSION" >&2
    rm -rf "$PARITY_WORKDIR/canboatjs"
  fi
fi
if [ ! -d "$PARITY_WORKDIR/canboatjs" ]; then
  git clone --quiet --depth 1 --branch "v$CBJS_VERSION" \
    https://github.com/canboat/canboatjs.git "$PARITY_WORKDIR/canboatjs" >&2
fi

docker run --rm \
  -v "$PARITY_WORKDIR/canboatjs:/parity/canboatjs:ro" \
  -v "$SCRIPT_DIR/canboat-parity-compare.cjs:/parity/compare.cjs:ro" \
  --entrypoint node "$IMAGE" /parity/compare.cjs /parity/canboatjs
