#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]] || ! jq -e '
	type == "object" and
	(.paths | type == "array" and length > 0 and all(.[]; type == "string")) and 
	(.pattern | type == "string")
' <<<"${1:-}" >/dev/null; then
	echo 'Usage: rg.sh {"paths":["FILE",...], "pattern":"PATTERN"}' >&2
	exit 2
fi

mapfile -d '' -t paths < <(jq -j '.paths[] | . + "\u0000"' <<<"$1")
IFS= read -r -d '' pattern < <(jq -j '.pattern + "\u0000"' <<<"$1")

if rg -H -- "$pattern" "${paths[@]}"; then
	exit 0
else
	rg_status=$?
	if [[ "$rg_status" -eq 1 ]]; then
		exit 0
	fi
	exit "$rg_status"
fi
