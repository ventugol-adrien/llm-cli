#!/usr/bin/env bash
APP_HOME="${HOME}/.local/share/llm-cli"
DB="$APP_HOME/.db"

mkdir -p "$APP_HOME"

for file in "$APP_HOME"/*.env; do
	if [[ -f "$file" ]]; then
		source "$file"
	fi
done

sqlite3 "$DB" <<-"EOF"
	CREATE TABLE IF NOT EXISTS sessions (
		id TEXT PRIMARY KEY,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	);
	CREATE TABLE IF NOT EXISTS messages (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		session_id TEXT NOT NULL REFERENCES sessions(id),
		role TEXT NOT NULL,
		content TEXT NOT NULL,
		metadata TEXT,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	);
EOF

db:init_session() {
	local session_id="${AGENT_SESSION_ID//\'/\'\'}"
	sqlite3 "$DB" "INSERT OR IGNORE INTO sessions (id) VALUES ('$session_id');"
}

db:insert_message() {
	local role="$1"
	local body="$2"
	local metadata="$3"
	local event_key="${4:-}"
	local turn_id="${5:-}"
	local session_id=${AGENT_SESSION_ID//\'/\'\'}
	role=${role//\'/\'\'}
	body=${body//\'/\'\'}
	event_key=${event_key//\'/\'\'}

	if [[ -n "$event_key" ]]; then
		if ! metadata=$(jq -cn \
			--argjson existing "$metadata" \
			--arg event_key "$event_key" \
			--arg turn_id "$turn_id" \
			'($existing // {}) + {event_key: $event_key, turn_id: $turn_id}'); then
			echo "Unable to encode message metadata" >&2
			return 1
		fi
	fi
	metadata=${metadata//\'/\'\'}

	if [[ "$metadata" == "null" ]]; then
		sqlite3 "$DB" "INSERT INTO messages (session_id, role, content, metadata) VALUES ('$session_id', '$role', '$body', NULL);"
	elif [[ -n "$event_key" ]]; then
		sqlite3 "$DB" <<-SQL
			BEGIN IMMEDIATE;
			INSERT INTO messages (session_id, role, content, metadata)
			SELECT '$session_id', '$role', '$body', '$metadata'
			WHERE NOT EXISTS (
				SELECT 1 FROM messages
				WHERE session_id = '$session_id'
				AND instr(COALESCE(metadata, ''), '"event_key":"$event_key"') > 0
			);
			COMMIT;
		SQL
	else
		sqlite3 "$DB" "INSERT INTO messages (session_id, role, content, metadata) VALUES ('$session_id', '$role', '$body', '$metadata');"
	fi
}

db:get_messages() {
	local rows
	local session_id="${AGENT_SESSION_ID//\'/\'\'}"
	rows=$(sqlite3 -json "$DB" "SELECT id, role, content, metadata, created_at FROM messages WHERE session_id == '$session_id' ORDER BY id;")
	if [[ -z "$rows" ]]; then
		printf '[]\n'
		return
	fi
	jq '[.[] | {
		role: .role,
		content: .content,
		metadata: .metadata,
		turn_id: (try (.metadata | fromjson | .turn_id) catch null),
		event_key: (try (.metadata | fromjson | .event_key) catch null),
		created_at: .created_at
	}]' <<<"$rows"
}
