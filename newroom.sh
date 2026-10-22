#!/bin/sh
# Spawn a brand-new ocirc room and print a digest-pinned invite to share.
#
#   ./newroom.sh            # random uuid room
#   ./newroom.sh my-room    # named room
#
# The room repo on the ephemeral registry holds everything: the client
# image (tag :24h) and the messages (untagged OCI 1.1 referrer artifacts).
# The repo path is baked into the image env (OCIRC_REPO) so the invite
# needs no env vars: running the image drops you straight into the room.
# A running container can't see its own image reference, so the repo has
# to be baked in. crane mutate rewrites one platform's config at a time
# (it flattens an index), so each platform is mutated separately and the
# index is reassembled with crane index append.
#
# The printed @sha256 digest pins the invite to these exact bytes: nobody
# can swap the image out from under your friends by re-pushing the mutable
# :24h tag.
set -eu

SRC="${OCIRC_IMAGE:-ghcr.io/jdolitsky/ocirc:latest}"
REG="${OCIRC_REGISTRY:-tmp.cgruser.dev}"
PLATFORMS="${OCIRC_PLATFORMS:-linux/amd64 linux/arm64}"

if command -v uuidgen >/dev/null 2>&1; then
    DEFAULT_ROOM=$(uuidgen | tr 'A-Z' 'a-z')
else
    DEFAULT_ROOM=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
fi
ROOM="${1:-$DEFAULT_ROOM}"
DST="$REG/$ROOM"

MANIFESTS=""
for platform in $PLATFORMS; do
    arch="${platform#*/}"
    echo "building $platform room image for $DST ..." >&2
    ref=$(crane mutate "$SRC" --platform "$platform" \
        --env "OCIRC_REPO=$DST" \
        -t "$DST:$arch" 2>/dev/null | tail -1)
    case "$ref" in
        *@sha256:*) ;;
        *) echo "crane mutate failed for $platform" >&2; exit 1 ;;
    esac
    MANIFESTS="$MANIFESTS -m $ref"
done

# shellcheck disable=SC2086
crane index append -t "$DST:24h" $MANIFESTS >/dev/null 2>&1

echo "docker run -it --rm $DST:24h@$(crane digest "$DST:24h")"
