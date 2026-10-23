#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]] || ! jq -e '
	type == "object" and
	(.paths | type == "array" and length > 0 and all(.[]; type == "string"))
' <<<"${1:-}" >/dev/null; then
	echo 'Usage: read.sh {"paths":["FILE",...]}' >&2
	exit 2
fi

jq -j '.paths[] | . + "\u0000"' <<<"$1" | xargs -0 tail -n +1 --
