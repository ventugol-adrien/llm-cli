#!/usr/bin/env bash

llama:base_url() {
	local url
	case "$1" in
	local)
		url="${LLM_CLI_LLAMA_LOCAL_URL:?Set LLM_CLI_LLAMA_LOCAL_URL to the local llama API base URL}"
		;;
	desktop)
		url="${LLM_CLI_LLAMA_DESKTOP_URL:?Set LLM_CLI_LLAMA_DESKTOP_URL to the desktop llama API base URL}"
		;;
	remote)
		url="${LLM_CLI_LLAMA_REMOTE_URL:?Set LLM_CLI_LLAMA_REMOTE_URL to the remote llama API base URL}"
		;;
	*)
		echo "Unknown location: $1" >&2
		return 1
		;;
	esac
	printf '%s' "${url%/}"
}
