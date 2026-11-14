#!/usr/bin/env bash

llama:base_url() {
	local url="${LLAMA_URL:-http://localhost:8080}"
	printf '%s' "${url%/}"
}
