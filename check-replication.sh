#!/usr/bin/env bash
#
# check-replication.sh — MariaDB/MySQL replica health check.
#
# Verifies that this server is replicating happily:
#   * replica I/O and SQL threads are running
#   * replication lag (Seconds_Behind_Master) is under your thresholds
#   * no Last_IO_Error / Last_SQL_Error is set
#   * GTID sets have not diverged (retrieved vs executed)
#
# Exit codes (Nagios/CI friendly): 0 OK, 1 warning, 2 critical, 3 unknown.
# On warning/critical it can email a digest (--to).
#
# Credentials come from ~/.my.cnf (or --defaults-file), so no password
# ever appears on the command line. The MySQL user needs REPLICATION CLIENT.
#
# Example crontab (every 5 minutes):
#   */5 * * * * /opt/bin/check-replication.sh --lag-warning 60 --lag-critical 300 \
#       --to dba@example.com --from "replcheck@db2.example.com" >> /var/log/replcheck.log 2>&1
#
set -euo pipefail

LAG_WARN=60
LAG_CRIT=300
TO_EMAIL=""
FROM_EMAIL="replcheck@$(hostname -f 2>/dev/null || hostname)"
DEFAULTS_FILE=""
JSON_OUT=0

usage() {
    cat <<'EOF'
Usage: check-replication.sh [options]

Options:
  --lag-warning SEC     warn when Seconds_Behind_Master >= SEC (default 60)
  --lag-critical SEC    critical when Seconds_Behind_Master >= SEC (default 300)
  --to EMAIL            send a mail digest on warning/critical (requires /usr/bin/mail)
  --from EMAIL          sender address for the digest (default replcheck@<hostname>)
  --defaults-file PATH  mysql --defaults-file for credentials (default ~/.my.cnf)
  --json                print the result as JSON instead of human text
  -h, --help            this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lag-warning)   LAG_WARN="$2"; shift 2 ;;
        --lag-critical)  LAG_CRIT="$2"; shift 2 ;;
        --to)            TO_EMAIL="$2"; shift 2 ;;
        --from)          FROM_EMAIL="$2"; shift 2 ;;
        --defaults-file) DEFAULTS_FILE="$2"; shift 2 ;;
        --json)          JSON_OUT=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
done

command -v mysql >/dev/null 2>&1 || {
    echo "UNKNOWN: mysql client not found in PATH" >&2; exit 3
}

MYSQL_ARGS=(-N --batch)
[ -n "$DEFAULTS_FILE" ] && MYSQL_ARGS+=(--defaults-file="$DEFAULTS_FILE")

# JSON-escape a string (minimal: backslash, quote, control chars).
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' | tr -d '\n'
}

# Fetch "Field: Value" vertical output from SHOW REPLICA/SLAVE STATUS.
# Tries the modern REPLICA spelling first, falls back to SLAVE.
STATUS_OUTPUT=""
IO_FIELD=""; SQL_FIELD=""
if STATUS_OUTPUT="$(mysql "${MYSQL_ARGS[@]}" -e 'SHOW REPLICA STATUS\G' 2>/dev/null)" \
    && [ -n "$STATUS_OUTPUT" ]; then
    IO_FIELD="Replica_IO_Running"; SQL_FIELD="Replica_SQL_Running"
elif STATUS_OUTPUT="$(mysql "${MYSQL_ARGS[@]}" -e 'SHOW SLAVE STATUS\G' 2>/dev/null)" \
    && [ -n "$STATUS_OUTPUT" ]; then
    IO_FIELD="Slave_IO_Running"; SQL_FIELD="Slave_SQL_Running"
fi

# Extract a field value from the vertical output (value may contain colons).
field() {
    printf '%s\n' "$STATUS_OUTPUT" | awk -v name="$1" '
        { line=$0; sub(/^ +/, "", line) }
        { key=line; sub(/:.*$/, "", key) }
        key == name { val=line; sub(/^[^:]*:[ \t]*/, "", val); print val; exit }
    '
}

# Count transactions inside a GTID set. Handles both formats:
#   MySQL 8:      uuid:1-100,uuid2:55        (UUID intervals)
#   MariaDB:      0-1-1-100,0-1-250          (domain-server-seq ranges)
gtid_count() {
    local set="$1" total=0 chunk range a b
    [ -z "$set" ] && { echo 0; return; }
    local old_ifs="$IFS"; IFS=','
    for chunk in $set; do
        if [[ "$chunk" == *:* ]]; then
            # MySQL 8 UUID:interval form — take the interval after the last colon.
            range="${chunk##*:}"
            if [[ "$range" == *-* ]]; then
                a="${range%%-*}"; b="${range##*-}"
                total=$(( total + b - a + 1 ))
            else
                total=$(( total + 1 ))
            fi
        else
            # MariaDB domain-server-seq[-end] form.
            local nfields
            nfields=$(awk -F'-' '{print NF}' <<<"$chunk")
            if [ "$nfields" -ge 4 ]; then
                a=$(cut -d'-' -f3 <<<"$chunk"); b=$(cut -d'-' -f4 <<<"$chunk")
                total=$(( total + b - a + 1 ))
            else
                total=$(( total + 1 ))
            fi
        fi
    done
    IFS="$old_ifs"
    echo "$total"
}

report() {
    # report <exit> <status> <message> [json-extra]
    local code="$1" status="$2" message="$3" extra="${4:-}"
    if [ "$JSON_OUT" -eq 1 ]; then
        printf '{"status":"%s","exit":%d,"message":"%s"%s}\n' \
            "$status" "$code" "$(json_escape "$message")" "$extra"
    else
        printf '%s: %s\n' "$status" "$message"
    fi
    if [ "$code" -ne 0 ] && [ -n "$TO_EMAIL" ]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s: %s\nHost: %s\n' "$status" "$message" "$(hostname -f 2>/dev/null || hostname)" \
                | mail -s "[replcheck] $status on $(hostname -s 2>/dev/null || hostname)" -r "$FROM_EMAIL" "$TO_EMAIL" \
                || echo "WARNING: failed to send alert mail" >&2
        else
            echo "WARNING: --to given but /usr/bin/mail not found; alert not sent" >&2
        fi
    fi
    exit "$code"
}

# --- connectivity / role checks ------------------------------------------------
if [ -z "$STATUS_OUTPUT" ]; then
    if mysql "${MYSQL_ARGS[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
        report 3 "UNKNOWN" "server reachable but SHOW REPLICA/SLAVE STATUS is empty — not configured as a replica"
    else
        report 3 "UNKNOWN" "cannot connect to MySQL/MariaDB (check ~/.my.cnf or --defaults-file)"
    fi
fi

IO_STATE="$(field "$IO_FIELD")"
SQL_STATE="$(field "$SQL_FIELD")"
LAG="$(field Seconds_Behind_Master)"
IO_ERR="$(field Last_IO_Error)"
SQL_ERR="$(field Last_SQL_Error)"
RETRIEVED="$(field Retrieved_Gtid_Set)"
EXECUTED="$(field Executed_Gtid_Set)"
SOURCE_HOST="$(field Master_Host)"; [ -z "$SOURCE_HOST" ] && SOURCE_HOST="$(field Source_Host)"

extra_json=",\"io_running\":\"$(json_escape "$IO_STATE")\",\"sql_running\":\"$(json_escape "$SQL_STATE")\""
extra_json+=",\"lag_seconds\":$( [ -n "$LAG" ] && [ "$LAG" != "NULL" ] && printf '%s' "$LAG" || printf 'null' )"
extra_json+=",\"source_host\":\"$(json_escape "$SOURCE_HOST")\""

# 1) Threads must be running — a stopped thread is always critical.
if [ "$IO_STATE" != "Yes" ]; then
    report 2 "CRITICAL" "replica I/O thread not running (state: '${IO_STATE:-empty}'; error: ${IO_ERR:-none})" "$extra_json"
fi
if [ "$SQL_STATE" != "Yes" ]; then
    report 2 "CRITICAL" "replica SQL thread not running (state: '${SQL_STATE:-empty}'; error: ${SQL_ERR:-none})" "$extra_json"
fi

# 2) Sticky errors are critical even if the threads recovered.
if [ -n "$IO_ERR" ]; then
    report 2 "CRITICAL" "Last_IO_Error: $IO_ERR" "$extra_json"
fi
if [ -n "$SQL_ERR" ]; then
    report 2 "CRITICAL" "Last_SQL_Error: $SQL_ERR" "$extra_json"
fi

# 3) Lag thresholds. NULL/empty lag with running threads is suspicious -> warning.
if [ -z "$LAG" ] || [ "$LAG" = "NULL" ]; then
    report 1 "WARNING" "Seconds_Behind_Master is NULL while threads run — replica may be stuck" "$extra_json"
elif [ "$LAG" -ge "$LAG_CRIT" ]; then
    report 2 "CRITICAL" "replication lag ${LAG}s >= critical threshold ${LAG_CRIT}s" "$extra_json"
elif [ "$LAG" -ge "$LAG_WARN" ]; then
    report 1 "WARNING" "replication lag ${LAG}s >= warning threshold ${LAG_WARN}s" "$extra_json"
fi

# 4) GTID divergence: retrieved transactions the replica has not executed yet.
if [ -n "$RETRIEVED" ] && [ -n "$EXECUTED" ] && [ "$RETRIEVED" != "$EXECUTED" ]; then
    pending=$(( $(gtid_count "$RETRIEVED") - $(gtid_count "$EXECUTED") ))
    if [ "$pending" -gt 0 ]; then
        report 1 "WARNING" "${pending} GTID transaction(s) retrieved but not yet executed" \
            "${extra_json},\"gtid_pending\":${pending}"
    fi
fi

report 0 "OK" "replication healthy — lag ${LAG:-0}s, threads running${SOURCE_HOST:+, source $SOURCE_HOST}" "$extra_json"
