#!/usr/bin/env bash
# Gate for this folder. Runs inside a throwaway Ubuntu 24.04 container as root, with the repo
# mounted read only. Installs Ansible in a venv, runs ansible-lint and a syntax check, checks
# that a run without app_image_tag stops at the assert before it changes anything, then runs
# the playbook twice against the container itself with the host_only tasks skipped. Checks what
# the first run changed, that the second run changed nothing, which tasks carry the tag, and the
# inventory line from the README.
set -euo pipefail

prog="$(basename -- "$0")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ansible-core 2.21 is the newest line that runs on Python 3.12, the Python of Ubuntu 24.04.
ansible_core_version="2.21.6"
ansible_lint_version="26.11.0"

work_root="/root/pf"
work_dir="${work_root}/05-ansible"
venv_dir="${work_root}/venv"
log_dir="${work_root}/logs"
test_inventory="${work_root}/test-inventory.ini"
service_user="appuser"
service_id="10001"
base_packages="ca-certificates curl python3-debian python3-requests ufw"
docker_sources="/etc/apt/sources.list.d/docker.sources"
docker_key="/etc/apt/keyrings/docker.asc"
doc_ip="203.0.113.10"
# No image is pushed and the test never runs one, so any fixed value does for the tag.
test_image_tag="verify-test"
tag_args=(-e "app_image_tag=${test_image_tag}")
tag_fail_msg="Set app_image_tag, for example -e app_image_tag=<commit sha>"

# The tasks without a tag, as ansible-playbook --list-tasks prints them. A pre_task has no role prefix.
expected_ran="Check that an image tag was given
base : Update the apt cache
base : Install the base packages
base : Create the service group
base : Create the service user
docker : Add the Docker apt repository
docker : Read the new Docker repository index before the install"

# The tasks that carry the host_only tag, as ansible-playbook --list-tasks prints them.
expected_host_only="base : Allow SSH through the firewall
base : Allow the app port through the firewall
base : Deny incoming traffic by default
base : Enable the firewall
docker : Install the Docker engine
docker : Enable and start the Docker service
app : Run the app container
app : Wait until /health answers"

usage() {
  cat <<EOF
Usage: ${prog} [-h]

Gate for the Ansible playbook: ansible-lint, syntax check, two runs against the
container itself with the host_only tasks skipped, and the inventory line from
the README. It installs packages and changes the system, so run it only in a
throwaway Ubuntu 24.04 container as root, with the repo mounted read only.
From the repo root:

  docker run --rm --name pf-ansible -v "\${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 05-ansible/verify.sh

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

recap_count() {
  # recap_count LOG FIELD: the number after FIELD= on the localhost line of the play recap
  local line
  line="$(grep -E '^localhost[[:space:]]+:' "$1" | tail -n 1 || true)"
  [ -n "$line" ] || fail "no recap line for localhost in $1"
  [[ $line =~ [[:space:]]$2=([0-9]+) ]] || fail "no $2= in the recap line: ${line}"
  echo "${BASH_REMATCH[1]}"
}

listed_tasks() {
  # listed_tasks LIST_LOG: one line per task from --list-tasks, "NAME<tab>TAGS: [...]", play line left out
  awk -F '\t' '$2 ~ /^TAGS: / && $1 !~ /^[[:space:]]*play #/ { sub(/^[[:space:]]+/, "", $1); print $1 "\t" $2 }' "$1"
}

[ "$(id -u)" -eq 0 ] || fail "run as root inside a container (see -h)"
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
  fail "no container detected. This script changes the system, run it only in a throwaway container (see -h)."
fi

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
export ANSIBLE_NOCOLOR=1 NO_COLOR=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$log_dir"

# a. Packages the base image lacks. Ubuntu server images already have them.
# ca-certificates lets ansible-galaxy reach Galaxy over HTTPS. python3-apt is for the apt module.
section "a. Installing python3, python3-venv, python3-apt and ca-certificates"
if ! { apt-get update -qq && apt-get install -y -qq --no-install-recommends \
  python3 python3-venv python3-apt ca-certificates; } >"${log_dir}/apt.log" 2>&1; then
  cat "${log_dir}/apt.log" >&2
  fail "apt-get install failed"
fi
python3 --version

# b. Work on a copy. On a Windows bind mount every folder looks world writable, and
# nothing may be written back to /repo.
section "b. Copying ${script_dir} to ${work_dir}"
rm -rf "$work_dir"
cp -r --no-preserve=mode "$script_dir" "$work_dir"
cd "$work_dir"
ls -A

# c. Tools in a venv, then the collections from requirements.yml.
section "c. Installing ansible-core ${ansible_core_version}, ansible-lint ${ansible_lint_version} and the collections"
python3 -m venv "$venv_dir"
if ! "${venv_dir}/bin/pip" install --quiet \
  "ansible-core==${ansible_core_version}" "ansible-lint==${ansible_lint_version}" \
  >"${log_dir}/pip.log" 2>&1; then
  cat "${log_dir}/pip.log" >&2
  fail "pip install failed"
fi
export PATH="${venv_dir}/bin:${PATH}"
ansible --version | sed -n 1p
ansible-lint --version | sed -n 1p
if ! ansible-galaxy collection install -r requirements.yml >"${log_dir}/galaxy.log" 2>&1; then
  cat "${log_dir}/galaxy.log" >&2
  fail "ansible-galaxy collection install failed"
fi
grep 'was installed successfully' "${log_dir}/galaxy.log" || true
# Each collection in requirements.yml must be installed at exactly the pinned version.
python - requirements.yml <<'EOF' || fail "collection versions do not match requirements.yml"
import json
import subprocess
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    wanted = {c["name"]: str(c["version"]) for c in yaml.safe_load(f)["collections"]}
listed = json.loads(subprocess.run(
    ["ansible-galaxy", "collection", "list", "--format", "json"],
    check=True, capture_output=True, text=True).stdout)
ok = True
for name, version in wanted.items():
    found = sorted({cols[name]["version"] for cols in listed.values() if name in cols})
    print(f"{name}: wanted {version}, installed {', '.join(found) or 'none'}")
    ok = ok and found == [version]
sys.exit(0 if ok else 1)
EOF

# d. Lint with the default rules.
section "d. ansible-lint"
rc=0
ansible-lint 2>&1 | tee "${log_dir}/lint.log" || rc=$?
expect_eq "ansible-lint exit code" "0" "$rc"
grep -q 'Passed: 0 failure(s), 0 warning(s)' "${log_dir}/lint.log" \
  || fail "ansible-lint did not report 0 failures and 0 warnings"

# e. The container itself is the target. It has no sudo and already runs as root.
# The venv comes first on PATH, so without the interpreter setting Ansible would find the
# venv's Python. A server runs the modules with /usr/bin/python3.
section "e. Test inventory and syntax check"
cat >"$test_inventory" <<'EOF'
[app]
localhost ansible_connection=local ansible_become=false ansible_python_interpreter=/usr/bin/python3
EOF
cat "$test_inventory"
rc=0
out="$(ansible-playbook -i "$test_inventory" site.yml "${tag_args[@]}" --syntax-check 2>&1)" || rc=$?
echo "$out"
expect_eq "syntax check exit code" "0" "$rc"
grep -qxF "playbook: site.yml" <<<"$out" || fail "syntax check did not name the playbook"

# f. Without app_image_tag the play must stop at the assert, before anything changes.
section "f. Run without app_image_tag: ansible-playbook -i ${test_inventory} site.yml --skip-tags host_only"
rc=0
ansible-playbook -i "$test_inventory" site.yml --skip-tags host_only >"${log_dir}/run0.log" 2>&1 || rc=$?
cat "${log_dir}/run0.log"
expect_eq "exit code without app_image_tag" "2" "$rc"
expect_eq "tasks started without app_image_tag" \
  "TASK [Gathering Facts]
TASK [Check that an image tag was given]" \
  "$(grep -o '^TASK \[[^]]*\]' "${log_dir}/run0.log")"
grep -qF -- "$tag_fail_msg" "${log_dir}/run0.log" || fail "the assert message [${tag_fail_msg}] was not printed"
expect_eq "failed count without app_image_tag" "1" "$(recap_count "${log_dir}/run0.log" failed)"
expect_eq "changed count without app_image_tag" "0" "$(recap_count "${log_dir}/run0.log" changed)"
if getent passwd "$service_user" >/dev/null; then
  fail "${service_user} exists after the run without app_image_tag"
fi
[ ! -e "$docker_sources" ] || fail "${docker_sources} exists after the run without app_image_tag"
if dpkg-query -W -f="\${Status}" ufw 2>/dev/null | grep -q 'ok installed'; then
  fail "ufw is installed after the run without app_image_tag"
fi
echo "checked: stopped at the assert with exit code 2; no ${service_user}, no ${docker_sources}, no ufw"

# g. First run, host_only tasks skipped.
section "g. Run 1: ansible-playbook -i ${test_inventory} site.yml ${tag_args[*]} --skip-tags host_only"
if ! ansible-playbook -i "$test_inventory" site.yml "${tag_args[@]}" --skip-tags host_only 2>&1 \
  | tee "${log_dir}/run1.log"; then
  fail "run 1 failed"
fi
expect_eq "run 1 failed count" "0" "$(recap_count "${log_dir}/run1.log" failed)"
expect_eq "run 1 unreachable count" "0" "$(recap_count "${log_dir}/run1.log" unreachable)"
run1_changed="$(recap_count "${log_dir}/run1.log" changed)"
[ "$run1_changed" -gt 0 ] || fail "run 1 changed nothing on a fresh container"

section "g. What run 1 did in the container"
for pkg in $base_packages; do
  expect_eq "dpkg status of ${pkg}" "install ok installed" \
    "$(dpkg-query -W -f="\${Status}" "$pkg" 2>/dev/null || true)"
done
echo "installed: ${base_packages}"

IFS=: read -r _ _ group_gid _ <<<"$(getent group "$service_user" || true)"
expect_eq "gid of group ${service_user}" "$service_id" "$group_gid"
IFS=: read -r _ _ user_uid user_gid _ user_home user_shell <<<"$(getent passwd "$service_user" || true)"
expect_eq "uid of ${service_user}" "$service_id" "$user_uid"
expect_eq "primary gid of ${service_user}" "$service_id" "$user_gid"
expect_eq "home of ${service_user}" "/nonexistent" "$user_home"
expect_eq "login shell of ${service_user}" "/usr/sbin/nologin" "$user_shell"
[ ! -e "$user_home" ] || fail "home dir ${user_home} of ${service_user} exists"
echo "user: $(getent passwd "$service_user")"

codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
arch="$(dpkg --print-architecture)"
[ -f "$docker_sources" ] || fail "${docker_sources} is missing"
for want in \
  "Types: deb" \
  "URIs: https://download.docker.com/linux/ubuntu" \
  "Suites: ${codename}" \
  "Components: stable" \
  "Architectures: ${arch}" \
  "Signed-By: ${docker_key}"; do
  grep -qxF -- "$want" "$docker_sources" || fail "line [${want}] not found in ${docker_sources}"
done
expect_eq "first line of ${docker_key}" "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$(head -n 1 "$docker_key")"
echo "${docker_sources}:"
cat "$docker_sources"
# apt read the signed index of the new repository, so docker-ce has a candidate from it.
policy="$(apt-cache policy docker-ce)"
candidate="$(awk '$1 == "Candidate:" { print $2 }' <<<"$policy")"
if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
  fail "docker-ce has no install candidate: ${policy}"
fi
grep -qF "https://download.docker.com/linux/ubuntu ${codename}/stable ${arch} Packages" <<<"$policy" \
  || fail "apt-cache policy docker-ce does not show the Docker repository: ${policy}"
echo "docker-ce candidate from download.docker.com: ${candidate}"

# The host_only tasks must not have run.
if dpkg-query -W -f="\${Status}" docker-ce 2>/dev/null | grep -q 'ok installed'; then
  fail "docker-ce is installed, a host_only task ran"
fi
grep -qxF "ENABLED=no" /etc/ufw/ufw.conf || fail "ufw is enabled, a host_only task ran"
if grep -q -- '--dport' /etc/ufw/user.rules; then
  fail "ufw has rules, a host_only task ran"
fi
echo "not done, as expected: docker-ce not installed, ufw not enabled and without rules"

# h. Second run: nothing may change.
section "h. Run 2: the same command again"
if ! ansible-playbook -i "$test_inventory" site.yml "${tag_args[@]}" --skip-tags host_only 2>&1 \
  | tee "${log_dir}/run2.log"; then
  fail "run 2 failed"
fi
expect_eq "run 2 changed count" "0" "$(recap_count "${log_dir}/run2.log" changed)"
expect_eq "run 2 failed count" "0" "$(recap_count "${log_dir}/run2.log" failed)"
expect_eq "run 2 unreachable count" "0" "$(recap_count "${log_dir}/run2.log" unreachable)"
echo "checked: run 2 reports changed=0 failed=0"

# i. Which tasks ran and which were skipped.
section "i. Tasks that ran in the container: --list-tasks --skip-tags host_only"
ansible-playbook -i "$test_inventory" site.yml "${tag_args[@]}" --list-tasks --skip-tags host_only \
  | tee "${log_dir}/list-ran.log" || fail "--list-tasks --skip-tags host_only failed"
ran_tasks="$(listed_tasks "${log_dir}/list-ran.log")"
[ -n "$ran_tasks" ] || fail "no tasks listed under --skip-tags host_only"
expect_eq "tasks with a tag under --skip-tags host_only" "" "$(awk -F '\t' '$2 != "TAGS: []"' <<<"$ran_tasks")"
expect_eq "tasks listed under --skip-tags host_only" \
  "$(awk '{ print $0 "\tTAGS: []" }' <<<"$expected_ran")" "$ran_tasks"
echo "checked: exactly the expected tasks ran, none of them tagged"

section "i. Tasks skipped in the container: --list-tasks --tags host_only"
ansible-playbook -i "$test_inventory" site.yml "${tag_args[@]}" --list-tasks --tags host_only \
  | tee "${log_dir}/list-skipped.log" || fail "--list-tasks --tags host_only failed"
expect_eq "tasks listed under --tags host_only" \
  "$(awk '{ print $0 "\tTAGS: [host_only]" }' <<<"$expected_host_only")" \
  "$(listed_tasks "${log_dir}/list-skipped.log")"
echo "checked: exactly the expected tasks carry host_only, and no other tag"

# j. The line from the README that writes inventory.ini. A stand-in for terraform prints
# a documentation address, because the real output needs an applied server.
section "j. The inventory line from README.md"
sed_lines="$(grep -F 'sed "s/APP_PUBLIC_IP/' README.md || true)"
expect_eq "number of inventory lines in README.md (English and Hebrew)" "2" "$(grep -c . <<<"$sed_lines")"
sed_line="$(head -n 1 <<<"$sed_lines")"
expect_eq "Hebrew copy of the inventory line" "$sed_line" "$(tail -n 1 <<<"$sed_lines")"
echo "$sed_line"
stub_dir="${work_root}/stub"
mkdir -p "$stub_dir"
cat >"${stub_dir}/terraform" <<EOF
#!/bin/sh
if [ "\$*" != "-chdir=04-terraform output -raw public_ip" ]; then
  echo "terraform stand-in: unexpected arguments: \$*" >&2
  exit 1
fi
printf '%s' '${doc_ip}'
EOF
chmod +x "${stub_dir}/terraform"
rm -f "${work_dir}/inventory.ini"
(cd "$work_root" && PATH="${stub_dir}:${PATH}" bash -c "$sed_line") \
  || fail "the inventory line from README.md failed"
grep -v '^#' "${work_dir}/inventory.ini" | grep . || fail "inventory.ini has no entries"
ansible-inventory -i "${work_dir}/inventory.ini" --list >"${log_dir}/inventory.json" \
  || fail "ansible-inventory could not read inventory.ini"
inventory_summary="$(python - "${log_dir}/inventory.json" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    inventory = json.load(f)
for host in inventory.get("app", {}).get("hosts", []):
    hostvars = inventory["_meta"]["hostvars"][host]
    print(host, hostvars.get("ansible_user"), hostvars.get("ansible_ssh_private_key_file"))
EOF
)"
expect_eq "hosts in group app" "${doc_ip} ubuntu ~/.ssh/my-key-pair.pem" "$inventory_summary"
echo "ansible-inventory: group app has ${inventory_summary}"

section "Results"
echo "ansible-lint: 0 failures, 0 warnings"
echo "syntax check: passed"
echo "run without app_image_tag: stopped at the assert, nothing changed"
echo "run 1: changed=${run1_changed} failed=0"
echo "run 2: changed=0 failed=0"
echo "skipped in the container (host_only):"
awk '{ print "  " $0 }' <<<"$expected_host_only"
echo
echo "VERIFY PASSED"
