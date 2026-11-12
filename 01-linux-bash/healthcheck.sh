#!/usr/bin/env bash
# Call the app's /health endpoint once and append one line to a log file.
# Silent when healthy, one line on stderr when not, so it fits in cron.
set -euo pipefail

prog="$(basename -- "$0")"

url="${HEALTH_URL:-http://127.0.0.1:8000/health}"
log_file="${HEALTH_LOG:-/var/log/portfolio-app/health.log}"
timeout="5"

usage() {
  cat <<EOF
Usage: ${prog} [-u URL] [-l FILE] [-t SECONDS] [-h]

Call the health URL once and append one line to the log file.
Prints nothing when healthy and one line on stderr when not.

  -u URL      health URL
              (default: \$HEALTH_URL or http://127.0.0.1:8000/health)
  -l FILE     log file
              (default: \$HEALTH_LOG or /var/log/portfolio-app/health.log)
  -t SECONDS  curl timeout in seconds (default: 5)
  -h          show this help

Exit codes: 0 healthy, 1 not healthy or log not writable, 2 usage error.
EOF
}

usage_error() {
  echo "${prog}: $*" >&2
  usage >&2
  exit 2
}

while getopts ":u:l:t:h" opt; do
  case "$opt" in
    u) url="$OPTARG" ;;
    l) log_file="$OPTARG" ;;
    t) timeout="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) usage_error "option -${OPTARG} needs a value" ;;
    *) usage_error "unknown option -${OPTARG}" ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"
[ -n "$url" ] || usage_error "URL must not be empty"
[ -n "$log_file" ] || usage_error "log file must not be empty"
[[ $timeout =~ ^[1-9][0-9]*$ ]] || usage_error "timeout must be a whole number of seconds, got: ${timeout}"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
http_code="000"
reason=""
ok_pattern='"status"[[:space:]]*:[[:space:]]*"ok"'

if ! command -v curl >/dev/null 2>&1; then
  reason="curl not found"
else
  # A failed request must not stop the script before the log line is written,
  # so the curl exit code is captured instead of tripping set -e.
  curl_rc=0
  response="$(curl --silent --max-time "$timeout" --write-out '\n%{http_code}' "$url" 2>/dev/null)" || curl_rc=$?
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ $http_code =~ ^[0-9]{3}$ ]] || http_code="000"

  if [ "$curl_rc" -ne 0 ]; then
    case "$curl_rc" in
      6) reason="could not resolve host" ;;
      7) reason="could not connect" ;;
      28) reason="timed out after ${timeout}s" ;;
      *) reason="curl exit code ${curl_rc}" ;;
    esac
  elif [ "$http_code" != "200" ]; then
    reason="unexpected HTTP status"
  elif ! [[ $body =~ $ok_pattern ]]; then
    reason="body does not report status ok"
  fi
fi

if [ -z "$reason" ]; then
  line="${ts} OK http=${http_code} url=${url}"
else
  line="${ts} FAIL http=${http_code} url=${url} reason=\"${reason}\""
fi

log_dir="$(dirname -- "$log_file")"
if ! { mkdir -p -- "$log_dir" && printf '%s\n' "$line" >>"$log_file"; } 2>/dev/null; then
  echo "${line} (not logged: cannot write ${log_file})" >&2
  exit 1
fi

if [ -n "$reason" ]; then
  echo "$line" >&2
  exit 1
fi
exit 0
