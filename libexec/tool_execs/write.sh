#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]] || ! jq -e '
	type == "object" and
	(.paths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
	(.content | type == "string")
' <<<"${1:-}" >/dev/null; then
	echo 'Usage: write.sh {"paths":["FILE",...],"content":"TEXT"}' >&2
	exit 2
fi

while IFS= read -r -d '' path; do
	jq -j '.content' <<<"$1" >"$path"
done < <(jq -j '.paths[] | . + "\u0000"' <<<"$1")
