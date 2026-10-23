#!/usr/bin/env bash

if [[ -z "$AGENT_SESSION_ID" ]]; then
	export AGENT_SESSION_ID="$(uuidgen)"
fi
