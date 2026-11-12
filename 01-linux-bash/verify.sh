#!/usr/bin/env bash
# End to end test for this folder. Runs inside a throwaway Ubuntu 24.04 container as root,
# with the repo mounted read only. Installs the app with setup.sh (twice), starts it as the
# service user, then runs healthcheck.sh and log-report.sh once healthy and once stopped.
set -euo pipefail

prog="$(basename -- "$0")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install_dir="/opt/portfolio-app"
service_user="appuser"
port="8000"
health_url="http://127.0.0.1:${port}/health"
log_file="/var/log/portfolio-app/health.log"
unit_file="/etc/systemd/system/portfolio-app.service"
work_dir="/tmp/verify"
ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

usage() {
  cat <<EOF
Usage: ${prog} [-h]

End to end test for setup.sh, healthcheck.sh and log-report.sh.
It installs packages, creates a user and starts the app, so run it only in a
throwaway Ubuntu 24.04 container as root, with the repo mounted read only.
From the repo root:

  docker run --rm -v "\${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 01-linux-bash/verify.sh

  -h  show this help

Exit codes: 0 all checks passed, 1 a check failed, 2 usage error.
EOF
}

usage_error() {
  echo "${prog}: $*" >&2
  usage >&2
  exit 2
}

while getopts ":h" opt; do
  case "$opt" in
    h) usage; exit 0 ;;
    *) usage_error "unknown option -${OPTARG}" ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"

fail() {
  echo "VERIFY FAILED: $*" >&2
  exit 1
}

expect_eq() {
  # expect_eq WHAT EXPECTED ACTUAL
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
}

section() {
  echo
  echo "---- $*"
}

port_open() {
  (: <"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

[ "$(id -u)" -eq 0 ] || fail "run as root inside a container (see -h)"
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
  fail "no container detected. This script changes the system, run it only in a throwaway container (see -h)."
fi

# All paths below are absolute. Running from / shows the scripts do not depend on the current directory.
cd /
mkdir -p "$work_dir"

runuser_pid=""
cleanup() {
  if [ -n "$runuser_pid" ] && kill -0 "$runuser_pid" 2>/dev/null; then
    kill "$runuser_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# a. Packages the base image lacks.
section "a. Installing python3, python3-venv and curl"
export DEBIAN_FRONTEND=noninteractive
if ! { apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 python3-venv curl; } \
  >"${work_dir}/apt.log" 2>&1; then
  cat "${work_dir}/apt.log" >&2
  fail "apt-get install failed"
fi
echo "$(python3 --version), $(curl --version | awk 'NR == 1 { print $1, $2 }')"

# b. setup.sh with defaults, then again to show it is safe to rerun.
section "b. setup.sh, first run"
if ! bash "${script_dir}/setup.sh" 2>&1 | tee "${work_dir}/setup1.log"; then
  fail "setup.sh first run failed"
fi
grep -q 'service not started' "${work_dir}/setup1.log" \
  || fail "setup.sh did not say that the service was not started"

IFS=: read -r _ _ _ _ _ user_home user_shell <<<"$(getent passwd "$service_user")"
expect_eq "login shell of ${service_user}" "/usr/sbin/nologin" "$user_shell"
[ ! -e "$user_home" ] || fail "home dir ${user_home} of ${service_user} was created"
for f in main.py requirements.txt; do
  [ -f "${install_dir}/${f}" ] || fail "${install_dir}/${f} is missing"
done
[ -x "${install_dir}/venv/bin/uvicorn" ] || fail "${install_dir}/venv/bin/uvicorn is missing"
expect_eq "owner of /var/log/portfolio-app" "$service_user" "$(stat -c %U /var/log/portfolio-app)"
for want in \
  "User=${service_user}" \
  "WorkingDirectory=${install_dir}" \
  "ExecStart=${install_dir}/venv/bin/uvicorn main:app --host 0.0.0.0 --port ${port}" \
  "Environment=APP_VERSION=0.1.0" \
  "Restart=on-failure" \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  "ProtectHome=true" \
  "ProtectSystem=full" \
  "WantedBy=multi-user.target"; do
  grep -qxF -- "$want" "$unit_file" || fail "line [${want}] not found in ${unit_file}"
done
echo "checked: user, files, venv, log dir owner, unit file lines"
unit_sum_1="$(sha256sum "$unit_file")"

section "b. setup.sh, second run"
if ! bash "${script_dir}/setup.sh" 2>&1 | tee "${work_dir}/setup2.log"; then
  fail "setup.sh second run failed"
fi
grep -q "User ${service_user} already exists" "${work_dir}/setup2.log" \
  || fail "second run did not find the existing user"
expect_eq "number of ${service_user} entries in /etc/passwd" "1" "$(grep -c "^${service_user}:" /etc/passwd || true)"
expect_eq "unit file after second run" "$unit_sum_1" "$(sha256sum "$unit_file")"
echo "checked: second run succeeded, one ${service_user} entry, unit file unchanged"

# c. Start the app as the service user, the way the unit file would.
section "c. Starting the app as ${service_user}"
(cd "$install_dir" && exec runuser -u "$service_user" -- \
  "${install_dir}/venv/bin/uvicorn" main:app --host 127.0.0.1 --port "$port") \
  >"${work_dir}/app.log" 2>&1 &
runuser_pid=$!

up=0
for ((i = 0; i < 60; i++)); do
  if curl --silent --fail --output /dev/null --max-time 2 "$health_url"; then
    up=1
    break
  fi
  if ! kill -0 "$runuser_pid" 2>/dev/null; then
    cat "${work_dir}/app.log" >&2
    fail "the app exited before /health answered"
  fi
  sleep 0.5
done
if [ "$up" -ne 1 ]; then
  cat "${work_dir}/app.log" >&2
  fail "/health did not answer within 30 seconds"
fi

# runuser stays as the parent, the app is its child.
app_pid="$(pgrep -n -P "$runuser_pid" || true)"
[ -n "$app_pid" ] || fail "no app process found under runuser (pid ${runuser_pid})"
case "$(ps -o args= -p "$app_pid")" in
  *uvicorn*main:app*) ;;
  *) fail "process ${app_pid} is not the app: $(ps -o args= -p "$app_pid")" ;;
esac
want_uid="$(id -u "$service_user")"
[ "$want_uid" -ne 0 ] || fail "${service_user} has uid 0"
expect_eq "real uid of the app" "$want_uid" "$(awk '/^Uid:/ { print $2 }' "/proc/${app_pid}/status")"
expect_eq "effective uid of the app" "$want_uid" "$(awk '/^Uid:/ { print $3 }' "/proc/${app_pid}/status")"
expect_eq "user of the app process" "$service_user" "$(ps -o user= -p "$app_pid" | tr -d ' ')"
echo "app is up: pid ${app_pid}, user ${service_user}, uid ${want_uid}, not root"

# d. Healthy run. The check runs as the service user, like the cron job would.
section "d. healthcheck.sh with the app running"
rc=0
out="$(runuser -u "$service_user" -- bash "${script_dir}/healthcheck.sh" 2>&1)" || rc=$?
echo "exit code: ${rc}"
expect_eq "healthcheck.sh exit code while healthy" "0" "$rc"
expect_eq "healthcheck.sh output while healthy" "" "$out"
expect_eq "log lines after first check" "1" "$(wc -l <"$log_file")"
line1="$(sed -n 1p "$log_file")"
ts1="${line1%% *}"
[[ $ts1 =~ $ts_re ]] || fail "first log line has no UTC timestamp: ${line1}"
expect_eq "first log line" "${ts1} OK http=200 url=${health_url}" "$line1"

# e. Stop the app and wait until nothing listens on the port.
section "e. Stopping the app"
kill "$app_pid"
for ((i = 0; i < 30; i++)); do
  port_open || break
  sleep 0.5
done
if port_open; then
  fail "port ${port} still open after stopping the app"
fi
wait "$runuser_pid" || true
runuser_pid=""
echo "app stopped, port ${port} closed"

# f. Failing run.
section "f. healthcheck.sh with the app stopped"
rc=0
out="$(runuser -u "$service_user" -- bash "${script_dir}/healthcheck.sh" 2>&1)" || rc=$?
echo "exit code: ${rc}"
echo "stderr: ${out}"
expect_eq "healthcheck.sh exit code while stopped" "1" "$rc"
expect_eq "log lines after second check" "2" "$(wc -l <"$log_file")"
line2="$(sed -n 2p "$log_file")"
ts2="${line2%% *}"
[[ $ts2 =~ $ts_re ]] || fail "second log line has no UTC timestamp: ${line2}"
expect_eq "second log line" "${ts2} FAIL http=000 url=${health_url} reason=\"could not connect\"" "$line2"
expect_eq "healthcheck.sh stderr while stopped" "$line2" "$out"

# g. Report.
section "g. log-report.sh"
rc=0
report="$(bash "${script_dir}/log-report.sh")" || rc=$?
expect_eq "log-report.sh exit code" "0" "$rc"
expected="Log file:          ${log_file}
Total checks:      2
Failures:          1
Last failure time: ${ts2}"
expect_eq "log-report.sh output" "$expected" "$report"
rc=0
bash "${script_dir}/log-report.sh" -l "${work_dir}/missing.log" 2>/dev/null || rc=$?
expect_eq "log-report.sh exit code for a missing log" "1" "$rc"
echo "checked: report matches the log, missing log exits 1"

# h. Evidence.
section "h. Results"
echo "Log (${log_file}):"
cat "$log_file"
echo
echo "Report:"
echo "$report"
echo
echo "VERIFY PASSED"
