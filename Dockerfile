FROM cgr.dev/chainguard/wolfi-base:latest AS build

RUN apk add --no-cache curl jq coreutils rlwrap

COPY chat.sh /usr/bin/ocirc
COPY entrypoint.sh /usr/bin/ocirc-entrypoint

# Collapse everything into a single layer.
FROM scratch

COPY --from=build / /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER nonroot

ENTRYPOINT ["/usr/bin/ocirc-entrypoint"]
