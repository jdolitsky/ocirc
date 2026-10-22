#!/bin/sh
# ocirc — serverless IRC-style chat over an OCI registry.
#
# A room is a repo. Every room contains one deterministic "anchor"
# artifact, and each message is an empty artifact attached to that anchor
# as an OCI 1.1 referrer, with the nick and text in manifest annotations.
# Clients poll the referrers API, which returns every message's
# annotations inline: reading the whole room is a single GET. The
# registry's own TTL garbage-collects the conversation.
#
# The client speaks the Distribution API directly with curl: no oras, no
# crane, no docker. Manifests are built with jq and pushed by digest, so
# messages never create tags.
set -eu

REG="${CHAT_REGISTRY:-tmp.cgruser.dev}"
ROOM_EXPLICIT="${ROOM:+1}"
ROOM="${ROOM:-lobby}"
POLL="${POLL_SECONDS:-2}"
HISTORY="${HISTORY:-20}"

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

# No nick given and a human is attached: let them pick one.
if [ -z "${NICK:-}" ] && [ "$INTERACTIVE" = 1 ]; then
    printf 'choose a nick: '
    IFS= read -r NICK || NICK=""
fi
NICK="${NICK:-anon-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

# Room names end up in registry paths, so restrict charset.
ROOM=$(printf '%s' "$ROOM" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_.-' | cut -c1-40)
[ -n "$ROOM" ] || { echo "invalid room name" >&2; exit 1; }

# Room images made by newroom.sh carry their own repo in OCIRC_REPO: the
# repo holds both the client image and the messages, so no ROOM env is
# needed. Explicit ROOM still works for direct runs (default room: lobby).
if [ -n "${OCIRC_REPO:-}" ] && [ -z "$ROOM_EXPLICIT" ]; then
    REPO="$OCIRC_REPO"
    REG="${OCIRC_REPO%%/*}"
    ROOM="${OCIRC_REPO##*/}"
else
    REPO="$REG/chat/$ROOM"
fi
RPATH="${REPO#*/}"

MANIFEST_MT='application/vnd.oci.image.manifest.v1+json'
MSG_AT='application/vnd.ocirc.msg.v1+json'

# The empty descriptor: config and sole layer of every ocirc artifact.
EMPTY_DIGEST='sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
EMPTY='{"mediaType":"application/vnd.oci.empty.v1+json","digest":"'$EMPTY_DIGEST'","size":2,"data":"e30="}'

# Every room shares one anchor: a byte-identical artifact manifest, so its
# digest is the same in every repo. Kept as a literal (not generated) so
# every client version agrees on the digest.
ANCHOR_JSON='{"schemaVersion":2,"mediaType":"'$MANIFEST_MT'","artifactType":"application/vnd.ocirc.room.v1+json","config":'$EMPTY',"layers":['$EMPTY']}'
ANCHOR="sha256:$(printf '%s' "$ANCHOR_JSON" | sha256sum | cut -d' ' -f1)"
ANCHOR_SIZE=${#ANCHOR_JSON}

STATE=$(mktemp -d)
LAST_DIGEST=""
POLL_PID=""
trap 'kill "$POLL_PID" 2>/dev/null; rm -rf "$STATE"' EXIT INT TERM
# The seen file is never empty (awk's NR==FNR idiom breaks on empty files).
echo '__none__' > "$STATE/seen"

say() { printf '\033[90m%s\033[0m\n' "$1"; }
prompt() { [ "$INTERACTIVE" = 1 ] && printf '> ' || :; }
clearline() { [ "$INTERACTIVE" = 1 ] && printf '\r\033[K' || :; }

TOKEN=$(curl -s "https://$REG/token?scope=repository:$RPATH:pull,push" \
    | jq -r '.token // "anonymous"')
AUTH="Authorization: Bearer $TOKEN"

ensure_empty_blob() {
    curl -sf -o /dev/null -H "$AUTH" \
        "https://$REG/v2/$RPATH/blobs/$EMPTY_DIGEST" && return 0
    loc=$(curl -sf -D - -o /dev/null -X POST -H "$AUTH" \
        "https://$REG/v2/$RPATH/blobs/uploads/" \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')
    case "$loc" in /*) loc="https://$REG$loc" ;; esac
    case "$loc" in *\?*) sep='&' ;; *) sep='?' ;; esac
    curl -sf -o /dev/null -X PUT -H "$AUTH" \
        -H 'Content-Type: application/octet-stream' \
        --data-binary '{}' "$loc${sep}digest=$EMPTY_DIGEST"
}

put_manifest() { # $1 = manifest json; echoes its digest
    d="sha256:$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
    curl -sf -o /dev/null -X PUT -H "$AUTH" \
        -H "Content-Type: $MANIFEST_MT" \
        --data-binary "$1" "https://$REG/v2/$RPATH/manifests/$d" || return 1
    echo "$d"
}

post() {
    ts=$(date +%s)
    m=$(jq -nc \
        --argjson empty "$EMPTY" \
        --arg mt "$MANIFEST_MT" --arg at "$MSG_AT" \
        --arg anchor "$ANCHOR" --argjson asize "$ANCHOR_SIZE" \
        --arg id "$ts-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --arg ts "$ts" --arg nick "$NICK" --arg msg "$1" \
        '{schemaVersion: 2, mediaType: $mt, artifactType: $at,
          config: $empty, layers: [$empty],
          subject: {mediaType: $mt, digest: $anchor, size: $asize},
          annotations: {"chat.id": $id, "chat.ts": $ts,
                        "chat.nick": $nick, "chat.msg": $msg}}')
    if d=$(put_manifest "$m"); then
        LAST_DIGEST="$d"
    else
        say "!! failed to send (registry hiccup, try again)"
    fi
}

unsend() { # $1 = message digest
    if curl -sf -o /dev/null -X DELETE -H "$AUTH" \
        "https://$REG/v2/$RPATH/manifests/$1"; then
        say "deleted ${1#sha256:} (clients that already saw it keep it on screen)"
    else
        say "!! could not delete $1 (already gone?)"
    fi
}

render() { # stdin: digest<TAB>ts<TAB>nick<TAB>msg lines, chronological
    while IFS="$(printf '\t')" read -r d ts nick msg; do
        hms=$(date -u -d "@$ts" +%H:%M:%S 2>/dev/null || echo '??:??:??')
        [ -n "${SHOW_IDS:-}" ] && hms="$hms ${d#sha256:}"
        printf '\033[90m[%s]\033[0m \033[36m<%s>\033[0m %b\n' "$hms" "$nick" "$msg"
    done
}

# One GET returns every message with its annotations inline. The + in the
# artifactType must be %-encoded or it decodes as a space in the query.
MSG_AT_ENC=$(printf '%s' "$MSG_AT" | sed 's/+/%2B/g')
fetch() {
    curl -sf -H "$AUTH" \
        "https://$REG/v2/$RPATH/referrers/$ANCHOR?artifactType=$MSG_AT_ENC" \
        | jq -r '.manifests[]? | [.digest,
            (.annotations["chat.ts"] // "0"),
            (.annotations["chat.nick"] // "???"),
            (.annotations["chat.msg"] // "")] | @tsv'
}

poller() {
    first=1
    while :; do
        if fetch | sort > "$STATE/now"; then
            awk -F'\t' 'NR==FNR{seen[$1];next} !($1 in seen)' \
                "$STATE/seen" "$STATE/now" \
                | sort -t"$(printf '\t')" -k2,2n > "$STATE/new"
            if [ "$first" = 1 ]; then
                tail -n "$HISTORY" "$STATE/new" > "$STATE/replay"
                mv "$STATE/replay" "$STATE/new"
                first=0
            fi
            if [ -s "$STATE/new" ]; then
                clearline
                render < "$STATE/new"
                prompt
            fi
            { echo '__none__'; cut -f1 "$STATE/now"; } > "$STATE/seen.next"
            mv "$STATE/seen.next" "$STATE/seen"
        fi
        sleep "$POLL"
    done
}

# Joining creates the room if needed: the anchor push is idempotent.
ensure_empty_blob || { echo "cannot reach $REPO" >&2; exit 1; }
put_manifest "$ANCHOR_JSON" >/dev/null || { echo "cannot create room in $REPO" >&2; exit 1; }

say "ocirc — room '$ROOM' on $REG as <$NICK>"
say "everything here is public and evaporates within 24h."
say "/quit leave · /oops delete your last message · /del <digest> delete by digest"
poller &
POLL_PID=$!

post ">> $NICK joined"
while prompt; IFS= read -r line; do
    case "$line" in
        "") continue ;;
        /quit) break ;;
        /oops)
            if [ -n "$LAST_DIGEST" ]; then
                unsend "$LAST_DIGEST"; LAST_DIGEST=""
            else
                say "nothing of yours to delete"
            fi ;;
        /del\ *) unsend "${line#/del }" ;;
        /who|/names) say "(no roster — presence is just whoever is polling)" ;;
        /*) say "unknown command: $line" ;;
        *) post "$line" ;;
    esac
done
post "<< $NICK left"
