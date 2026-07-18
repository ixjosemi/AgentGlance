#!/bin/sh

event=${1:-}
if [ -z "$event" ]; then
    exit 0
fi

script_directory=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd)
tty_name=$(/bin/ps -o tty= -p "$PPID" 2>/dev/null | /usr/bin/tr -d ' ')
case "$tty_name" in
    ""|"??") AGENTGLANCE_TTY="" ;;
    /dev/*) AGENTGLANCE_TTY=$tty_name ;;
    *) AGENTGLANCE_TTY="/dev/$tty_name" ;;
esac
export AGENTGLANCE_TTY

"$script_directory/agentglance" hook claude "$event" --pid "$PPID" >/dev/null 2>&1 || true
exit 0
