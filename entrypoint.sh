#!/bin/sh
# Interactive sessions get rlwrap: it redraws your in-progress input line
# whenever the poller prints incoming messages, and adds readline editing.
if [ -t 0 ]; then
    exec rlwrap -C ocirc /usr/bin/ocirc "$@"
fi
exec /usr/bin/ocirc "$@"
