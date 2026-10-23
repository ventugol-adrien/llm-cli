#!/usr/bin/env bash
set -e

progress:step() {
	printf '[step] %s\n' "$*" >&2
}

progress:run() {
	if [[ $# -lt 3 ]]; then
		printf 'Usage: progress:run LABEL OUTPUT_FILE COMMAND [ARGUMENT...]\n' >&2
		return 2
	fi

	local label="$1"
	local output_file="$2"
	local command_pid
	local command_status=0
	local frame_index=0
	local -a frames=('|' '/' '-' '\')
	shift 2

	if [[ -t 2 ]]; then
		"$@" >"$output_file" &
		command_pid=$!
		while kill -0 "$command_pid" 2>/dev/null; do
			printf '\r\033[2K[%s] %s' "${frames[frame_index]}" "$label" >&2
			frame_index=$(((frame_index + 1) % ${#frames[@]}))
			sleep 0.1
		done
		if wait "$command_pid"; then
			command_status=0
		else
			command_status=$?
		fi
		printf '\r\033[2K' >&2
	else
		progress:step "$label"
		if "$@" >"$output_file"; then
			command_status=0
		else
			command_status=$?
		fi
	fi

	if [[ "$command_status" -eq 0 ]]; then
		printf '[done] %s\n' "$label" >&2
	else
		printf '[failed] %s (exit %s)\n' "$label" "$command_status" >&2
	fi
	return "$command_status"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
	return 0
fi

RESPONSE_ESCAPE_PENDING=false
RESPONSE_STAR_COUNT=0

while IFS= read -r -N 1 character || [[ -n "$character" ]]; do
    if [[ "$RESPONSE_ESCAPE_PENDING" == true ]]; then
        case "$character" in
            n) printf '\n' ;;
            t) printf '\t' ;;
            *) printf '\\%s' "$character" ;;
        esac
        RESPONSE_ESCAPE_PENDING=false
    elif [[ "$character" == "*" ]]; then
        RESPONSE_STAR_COUNT=$((RESPONSE_STAR_COUNT + 1))
    elif [[ "$RESPONSE_STAR_COUNT" -gt 0 ]]; then
        if [[ "$RESPONSE_STAR_COUNT" -eq 1 ]]; then
            printf '\n*'
        else
            for ((index = 0; index < RESPONSE_STAR_COUNT; index++)); do
                printf '*'
            done
        fi
        RESPONSE_STAR_COUNT=0
        if [[ "$character" == "\\" ]]; then
            RESPONSE_ESCAPE_PENDING=true
        elif [[ "$character" == "#" ]]; then
            printf '\n#'
        else
            printf '%s' "$character"
        fi
    elif [[ "$character" == "\\" ]]; then
        RESPONSE_ESCAPE_PENDING=true
    elif [[ "$character" == "#" ]]; then
        printf '\n#'
    else
        printf '%s' "$character"
    fi
done

if [[ "$RESPONSE_ESCAPE_PENDING" == true ]]; then
    printf '\\'
fi
if [[ "$RESPONSE_STAR_COUNT" -gt 0 ]]; then
    if [[ "$RESPONSE_STAR_COUNT" -eq 1 ]]; then
        printf '\n*'
    else
        for ((index = 0; index < RESPONSE_STAR_COUNT; index++)); do
            printf '*'
        done
    fi
fi
printf '\n'
