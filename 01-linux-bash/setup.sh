#!/usr/bin/env bash
# Install the portfolio app on an Ubuntu or Debian host and register it with systemd.
# Run as root. Safe to run more than once.
set -euo pipefail

prog="$(basename -- "$0")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

src_dir="${script_dir}/../app"
install_dir="/opt/portfolio-app"
service_user="appuser"
port="8000"

log_dir="/var/log/portfolio-app"
unit_name="portfolio-app.service"
unit_file="/etc/systemd/system/${unit_name}"

usage() {
  cat <<EOF
Usage: ${prog} [-s DIR] [-d DIR] [-u NAME] [-p PORT] [-h]

Install the portfolio app as a systemd service. Run as root on Ubuntu or Debian.
Safe to run more than once.

  -s DIR   app source dir with main.py and requirements.txt
           (default: ../app next to this script)
  -d DIR   install dir (default: /opt/portfolio-app)
  -u NAME  service user (default: appuser)
  -p PORT  port the app listens on (default: 8000)
  -h       show this help

Exit codes: 0 done, 1 a step failed, 2 usage error.
EOF
}

usage_error() {
  echo "${prog}: $*" >&2
  usage >&2
  exit 2
}

die() {
  echo "${prog}: error: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

while getopts ":s:d:u:p:h" opt; do
  case "$opt" in
    s) src_dir="$OPTARG" ;;
    d) install_dir="$OPTARG" ;;
    u) service_user="$OPTARG" ;;
    p) port="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) usage_error "option -${OPTARG} needs a value" ;;
    *) usage_error "unknown option -${OPTARG}" ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"

if ! [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || [ "$port" -gt 65535 ]; then
  usage_error "port must be a number from 1 to 65535, got: ${port}"
fi
if [[ $install_dir != /* || $install_dir =~ [[:space:]] ]]; then
  usage_error "install dir must be an absolute path without spaces, got: ${install_dir}"
fi
[ -n "$service_user" ] || usage_error "service user must not be empty"

venv_dir="${install_dir}/venv"

# a. Preconditions.
step "Checking root, python3 and the venv module"
[ "$(id -u)" -eq 0 ] || die "run as root, for example: sudo ${0}"
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install it: apt-get install python3 python3-venv"
# Debian and Ubuntu ship venv without ensurepip unless python3-venv is installed.
python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || die "the python3 venv module is not usable. Install it: apt-get install python3-venv"
for f in main.py requirements.txt; do
  [ -f "${src_dir}/${f}" ] || die "${src_dir}/${f} not found. Point -s at the app folder."
done

# b. Service user: system account, no login shell, no home dir.
if id -u "$service_user" >/dev/null 2>&1; then
  step "User ${service_user} already exists"
else
  step "Creating system user ${service_user}"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$service_user"
fi
service_group="$(id -gn "$service_user")"

# c. App files. Owned by root so the service user cannot change its own code.
step "Copying main.py and requirements.txt to ${install_dir}"
install -d -m 0755 "$install_dir"
install -m 0644 "${src_dir}/main.py" "${src_dir}/requirements.txt" "$install_dir/"

# d. Virtual environment and dependencies.
if [ -x "${venv_dir}/bin/python" ]; then
  step "Venv ${venv_dir} already exists"
else
  step "Creating venv ${venv_dir}"
  python3 -m venv "$venv_dir"
fi
step "Installing requirements into the venv"
"${venv_dir}/bin/pip" install --quiet --no-cache-dir --disable-pip-version-check \
  -r "${install_dir}/requirements.txt"

# e. Log folder for healthcheck.sh.
step "Making sure ${log_dir} exists, owned by ${service_user}"
install -d -m 0755 -o "$service_user" -g "$service_group" "$log_dir"

# f. systemd unit file.
step "Writing ${unit_file}"
cat >"$unit_file" <<EOF
[Unit]
Description=Portfolio app (FastAPI on uvicorn)
After=network.target

[Service]
User=${service_user}
WorkingDirectory=${install_dir}
Environment=APP_VERSION=0.1.0
ExecStart=${venv_dir}/bin/uvicorn main:app --host 0.0.0.0 --port ${port}
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$unit_file"

# g. Start it, but only where systemd is actually running.
if [ -d /run/systemd/system ]; then
  step "Reloading systemd and starting ${unit_name}"
  systemctl daemon-reload
  systemctl enable --now "$unit_name"
else
  step "systemd is not running here: unit file written to ${unit_file}, service not started"
fi

step "Done"
