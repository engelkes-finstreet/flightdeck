#!/bin/bash
# Flightdeck's usage tap.
#
# Claude Code hands its status-line command a JSON payload on stdin that
# includes `rate_limits` — the live 5-hour and weekly figures, refreshed on
# every render of every session. Nothing else on disk carries those numbers
# while they are current, so Flightdeck reads them from here.
#
# This script is a pass-through: it saves `rate_limits` to
# ~/.claude/flightdeck-usage.json and then runs your real status line with the
# same payload, so your status line looks and behaves exactly as before.
#
#   "statusLine": {
#     "type": "command",
#     "command": "~/workspace/flightdeck/scripts/flightdeck-usage.sh npx -y ccstatusline@latest",
#     "padding": 0
#   }
#
# `rate_limits` is present only for Claude.ai subscribers, and only after a
# session's first API response — until then this writes nothing and Flightdeck
# falls back to the (older) figures cached in ~/.claude.json.
set -uo pipefail

payload=$(cat)
out="$HOME/.claude/flightdeck-usage.json"
tmp="$out.tmp.$$"

# Never let the tap break the status line: every failure here is silent, and
# the payload still reaches the wrapped command below.
if [ -d "$HOME/.claude" ] && command -v jq >/dev/null 2>&1; then
    if printf '%s' "$payload" \
        | jq -ce --argjson at "$(date +%s)" \
            'select(.rate_limits != null) | {written_at: $at, rate_limits: .rate_limits}' \
            >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$out" 2>/dev/null
    fi
    rm -f "$tmp" 2>/dev/null
fi

# No wrapped command means the status line would render blank, so say what is
# running rather than leaving the row empty.
if [ "$#" -eq 0 ]; then
    echo "flightdeck usage tap"
    exit 0
fi

printf '%s' "$payload" | exec "$@"
