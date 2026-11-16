#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]] || ! jq -e '
	type == "object" and
	(.path | type == "string" and length > 0) and
	(.depth | type == "number" and floor == . and . >= 0)
' <<<"${1:-}" >/dev/null; then
	echo 'Usage: tree.sh {"path":"DIRECTORY", "depth":N}' >&2
	exit 2
fi

jq -j '.path + "\u0000"' <<<"$1" | xargs -0 tree -L "$(jq -r '.depth' <<<"$1")"
