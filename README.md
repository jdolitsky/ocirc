# ocirc

IRC-style chat with no chat server. Clients talk to an anonymous, ephemeral
OCI registry
([`tmp.cgruser.dev`](https://edu.chainguard.dev/chainguard/containers/registry/temporary-registry/))
and nothing else. There is no websocket, no broker, and no database. All
state is ordinary registry content: a room is a repo, a message is an OCI
1.1 referrer artifact, history is one call to the referrers API, and
retention is handled by the registry's TTL. Clients never connect to each
other, and the client itself is a shell script that speaks the Distribution
API over curl.

```
  alice ──┐                          ┌── bob
          │   push message manifest  │
          ├────────────────────────► │
          │                          │
          │   tmp.cgruser.dev/<room> │
          │                          │
          ◄──── poll referrers ──────┤
          │     (one GET, inline     │
  carol ──┘      annotations)        └── dave
```

## Create a room and invite friends

A room is a repo on the ephemeral registry, and that one repo holds
everything: the client image and the messages. Create one with the script:

```sh
./newroom.sh            # random uuid room
./newroom.sh my-room    # named room
```

or as a plain oneliner (requires
[`crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane)):

```sh
REPO=tmp.cgruser.dev/$(uuidgen | tr 'A-Z' 'a-z') \
  && for a in amd64 arm64; do crane mutate ghcr.io/jdolitsky/ocirc:latest \
       --platform linux/$a --env OCIRC_REPO=$REPO -t $REPO:$a >/dev/null; done \
  && crane index append -t $REPO:24h -m $REPO:amd64 -m $REPO:arm64 >/dev/null \
  && echo "docker run -it --rm $REPO:24h@$(crane digest $REPO:24h)"
```

Either way it prints something like:

```
docker run -it --rm tmp.cgruser.dev/9f1c2ab4-71d2-4f05-9e57-0c2b9a6f3d11:24h@sha256:ab12...ef90
```

Send that line to your friends. That's the entire invite: no accounts, no
tokens, no env vars, no server to stand up. The pieces of it:

1. **The repo is the room.** The client image is copied into
   `tmp.cgruser.dev/<room>`, and messages live in the same repo the image
   came from. The repo path rides along inside the image env
   (`OCIRC_REPO`), because a running container can't see its own image
   reference. Baking an env var means rewriting each platform's config,
   and `crane mutate` flattens an index to one platform, so the oneliner
   mutates each platform and reassembles the index with
   `crane index append`.
2. **A uuid room name.** Rooms have no access control. The repo name is
   the only secret, so it should be unguessable.
3. **The ephemeral registry hosts it all.** Friends pull the client from
   the same anonymous registry the chat runs on, with no credentials. The
   `:24h` duration tag means the room's image, like its messages, is gone
   within 24 hours.
4. **A pinned digest.** Anyone on the internet can re-push the `:24h` tag
   at any time. The `@sha256:...` suffix makes Docker verify that your
   friends run exactly the image you created, regardless of what happens
   to the tag later. Never share an invite to an anonymous registry
   without a digest.

You can also run `ghcr.io/jdolitsky/ocirc:latest` directly. Messages never
go to ghcr: with no `OCIRC_REPO` set, the client falls back to the shared
`lobby` room at `tmp.cgruser.dev/chat/lobby` (or any `-e ROOM=` you pass).

## Design

The OCI Distribution Spec (1.1) provides a small set of operations: push a
blob, push or delete a manifest by digest, and list the referrers of a
manifest. That set is sufficient for a basic message bus, with no tags
involved at all:

| chat concept | OCI concept |
|---|---|
| room | repository: `tmp.cgruser.dev/<room>` (client image + messages) |
| room anchor | one deterministic, untagged artifact manifest |
| message | untagged artifact manifest with `subject` = the anchor |
| message body & nick | manifest **annotations** |
| send | `PUT /v2/<room>/manifests/<digest>` |
| receive | `GET /v2/<room>/referrers/<anchor>` (annotations come inline) |
| delete a message | `DELETE /v2/<room>/manifests/<digest>` |
| ordering | `chat.ts` annotation, sorted client-side |
| room creation | implicit: the anchor push is idempotent |
| retention / GC | the registry's own TTL (everything ≤ 24h) |

### The room anchor

Referrers attach to a subject manifest, so every room needs exactly one
manifest for messages to point at. The anchor is an empty artifact whose
bytes are a fixed literal in the client, which makes its digest identical
in every room and across every client. Each client pushes it on join;
since the content is byte-identical, the push is an idempotent no-op after
the first. Whoever joins first creates the room.

### Message format

A message is an empty artifact manifest (config and single layer are the
standard 2-byte empty descriptor) with the payload in annotations and the
anchor as its `subject`:

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "artifactType": "application/vnd.ocirc.msg.v1+json",
  "config":  { "...": "empty descriptor" },
  "layers": [{ "...": "empty descriptor" }],
  "subject": { "digest": "sha256:<anchor>", "...": "" },
  "annotations": {
    "chat.id":   "1792702161-4e13",
    "chat.ts":   "1792702161",
    "chat.nick": "alice",
    "chat.msg":  "hello world"
  }
}
```

The manifest is pushed **by digest**, not by tag, so messages never appear
in the tag listing. `chat.id` contains a random component so that two
messages with identical text still produce distinct digests, which keeps
digest-level operations (like deletion) scoped to one message.

### Receiving

The referrers API returns each referrer's annotations inline, so one GET
yields every message in the room, body included, with no per-message
fetches:

```sh
curl -s -H 'Authorization: Bearer anonymous' \
  "https://tmp.cgruser.dev/v2/<room>/referrers/<anchor-digest>" \
  | jq -r '.manifests[].annotations["chat.msg"]'
```

Each client keeps one piece of state, in a tmpfs file that dies with the
container: the set of message digests it has already displayed. Every 2
seconds it fetches the referrers list, renders the digests it hasn't seen
(sorted by `chat.ts`), and updates the set. There are no cursors, offsets,
or acks, so any number of clients can join and leave without a handshake.
On join, the client renders the most recent 20 messages as history.

### Deleting messages

A message is deleted by deleting its manifest, which removes it from the
referrers listing:

```sh
curl -s -X DELETE -H 'Authorization: Bearer anonymous' \
  "https://tmp.cgruser.dev/v2/<room>/manifests/sha256:<message-digest>"
```

In the client: `/oops` deletes your most recent message, and
`/del <digest>` deletes any message (run with `-e SHOW_IDS=1` to see
digests inline). Deletion only affects clients that have not yet seen the
message. Clients that already rendered it keep it on screen.

### Behavior inherited from the registry

- **Retention.** `tmp.cgruser.dev` expires content automatically (24h
  max), so a room's history is removed on its own. There is nothing to
  clean up and no way to keep anything longer.
- **Presence.** There is no roster. "Who's here" means "whoever is
  polling". Join and leave notices are ordinary messages posted by the
  client.
- **Operations.** Durability, consistency of the referrers index, fan-out
  to N readers, and rate limiting are all the registry's job. The client
  is one POSIX shell script.

## Threat model

- **Everything is public.** Anyone who knows or guesses a room name can
  read the full history within the TTL window without joining, and can
  post to it. A uuid room name is a bearer token and nothing more.
- **Nicks are unauthenticated.** Anyone can post under any nick.
- **Anyone can delete anything.** Manifest deletion is as anonymous as
  manifest pushing.
- **Pin digests.** Mutable tags on an anonymous registry carry no trust.
  The invite format includes a digest for this reason.
- Don't say anything here you wouldn't put on a billboard with a 24-hour
  lease.

## Client commands & knobs

| command | |
|---|---|
| `/quit` | leave (posts a departure message) |
| `/oops` | delete the last message you sent |
| `/del <digest>` | delete any message by digest |
| `/who` | explains why there's no roster |

| env | default | |
|---|---|---|
| `OCIRC_REPO` | baked into room images | full repo holding the room (image + messages) |
| `ROOM` | `lobby` | fallback room under `<registry>/chat/` for direct runs; overrides `OCIRC_REPO` if set |
| `NICK` | prompt, or `anon-<rand>` | display name |
| `SHOW_IDS` | unset | set to `1` to show each message's digest (for `/del`) |
| `POLL_SECONDS` | `2` | poll interval |
| `HISTORY` | `20` | messages replayed on join |
| `CHAT_REGISTRY` | `tmp.cgruser.dev` | any OCI-1.1 registry allowing anonymous push works |

Interactive sessions are wrapped in `rlwrap`, so incoming messages redraw
your half-typed line instead of clobbering it, and you get readline editing
plus input history. Piped stdin skips all prompts and rlwrap, so
`echo hi | docker run --rm -i -e NICK=bot ...` works for bots.

## Build it yourself

Nothing here requires the published image:

```sh
git clone https://github.com/jdolitsky/ocirc && cd ocirc
docker build -t ocirc .
docker run -it --rm ocirc
```

The image is `cgr.dev/chainguard/wolfi-base` plus `curl`, `jq`,
`coreutils`, and `rlwrap`, and the two shell scripts in this repo, squashed
to a single layer via a multi-stage build. The client needs no registry
tooling at all; `crane` is only used on the host by `newroom.sh`. A GitHub
Action publishes `ghcr.io/jdolitsky/ocirc:latest` (linux/amd64 + arm64) on
every push to `main`.

## FAQ

**Is this serious?** The chat, no. The underlying point, yes: an OCI
registry is a content-addressed, globally distributed key-value store with
a standardized API, and it can host more kinds of data than images.

**Why referrers instead of tags?** An earlier version stored each message
as a tag. The referrers API is cleaner on every axis: the room's tag
listing stays empty, reading the whole room is one GET instead of a tag
list plus a manifest fetch per message, and the response carries the
annotations inline. It also exercises an OCI 1.1 feature the way it was
meant to be used: artifacts attached to a subject.

**Why doesn't the client need oras or crane?** Everything the client does
is three HTTP calls: PUT a manifest by digest, GET a referrers list, and
DELETE a manifest. curl, jq, and sha256sum cover that. The empty config
blob is uploaded once per room through the standard two-step blob upload.

**What's the message size limit?** Whatever the registry accepts as a
manifest (annotation values are strings in that JSON). Plenty for chat.

**Can I run a room on a different registry?** Yes. `CHAT_REGISTRY` points
anywhere that implements OCI 1.1 referrers and allows anonymous (or
docker-login'd) push and manifest delete. On registries that don't expire
content, you lose the automatic TTL.
