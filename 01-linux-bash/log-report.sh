#!/usr/bin/env bash
# Summarize the log written by healthcheck.sh: total checks, failures, last failure time.
set -euo pipefail

prog="$(basename -- "$0")"

log_file="${HEALTH_LOG:-/var/log/portfolio-app/health.log}"

usage() {
  cat <<EOF
Usage: ${prog} [-l FILE] [-h]

Summarize the health log written by healthcheck.sh.

  -l FILE  log file
           (default: \$HEALTH_LOG or /var/log/portfolio-app/health.log)
  -h       show this help

Exit codes: 0 report printed, 1 log file missing or unreadable, 2 usage error.
EOF
}

usage_error() {
  echo "${prog}: $*" >&2
  usage >&2
  exit 2
}

while getopts ":l:h" opt; do
  case "$opt" in
    l) log_file="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) usage_error "option -${OPTARG} needs a value" ;;
    *) usage_error "unknown option -${OPTARG}" ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"
[ -n "$log_file" ] || usage_error "log file must not be empty"

if [ ! -e "$log_file" ]; then
  echo "${prog}: log file not found: ${log_file}" >&2
  exit 1
fi
if [ ! -f "$log_file" ] || [ ! -r "$log_file" ]; then
  echo "${prog}: cannot read log file: ${log_file}" >&2
  exit 1
fi

# Each check is one line: <timestamp> OK|FAIL http=... url=... [reason="..."]
summary="$(awk '
  $2 == "OK"   { total++ }
  $2 == "FAIL" { total++; failures++; last = $1 }
  END { printf "%d %d %s\n", total, failures, (last == "" ? "none" : last) }
' "$log_file")"
read -r total failures last_failure <<<"$summary"

printf 'Log file:          %s\n' "$log_file"
printf 'Total checks:      %s\n' "$total"
printf 'Failures:          %s\n' "$failures"
printf 'Last failure time: %s\n' "$last_failure"
