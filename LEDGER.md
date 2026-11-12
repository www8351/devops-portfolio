# LEDGER

Entry format:

```
Issue:  [what / why]
Action: [what was done or what is planned]
Status: [OPEN | IN PROGRESS | DONE | BLOCKED | FINAL]
```

## ISSUES (current state)

Ordered queue for the build run, steps 0 to 7. Work one step at a time, in order. Resume from the first step that is not DONE. A step is DONE only when its gate passes with real command output. A step that passes moves to ACTIONS with start time, end time and the gate evidence.

### Step 1. app/ and root README

```
Issue:  Step 1. Build app/main.py (FastAPI, exactly two endpoints: GET /health returns {"status": "ok"}, GET /version returns {"version": <value>} from env var APP_VERSION, default "0.1.0"), app/requirements.txt (runtime only: fastapi, uvicorn), app/requirements-dev.txt (first line "-r requirements.txt", then pytest, httpx), every package pinned to the exact installed version, app/tests/test_health.py (two TestClient tests), app/README.md and root README.md with the owner's exact wording, ".pytest_cache/" in .gitignore. Commit app code, requirements and tests first, both readme files second.
Action: Gate: pytest passes from app/ inside .venv, and both endpoints answer on a live uvicorn. Started 2026-11-12 05:45 (+0200).
Status: IN PROGRESS
```

### Step 2. 01-linux-bash/

```
Issue:  Step 2. Build setup.sh (service user, venv, install app, systemd unit file), healthcheck.sh (calls /health, writes a timestamped log line, non-zero exit on failure, cron friendly), log-report.sh (summarizes that log: total checks, failures, last failure time). All use set -euo pipefail and print a usage message. Folder readme per the readme rules.
Action: Gate: shellcheck clean. healthcheck.sh and log-report.sh run for real in an Ubuntu container against the running app, once healthy and once with the app stopped, and both results are correct.
Status: OPEN
```

### Step 3. 02-docker/

```
Issue:  Step 3. Build a multi-stage Dockerfile (pinned base image, non-root user, HEALTHCHECK, runtime dependencies only, APP_VERSION as a build arg), .dockerignore, docker-compose.yml. Folder readme per the readme rules.
Action: Gate: hadolint clean. Image builds. Container runs, both endpoints answer, the process is not root, health status becomes healthy. Report the image size.
Status: OPEN
```

### Step 4. 03-ci-cd/

```
Issue:  Step 4. Build .github/workflows/ci.yml with jobs lint (ruff), test (pytest), build (docker build). Push to GHCR only on main, tagged with the commit SHA, which is also passed as APP_VERSION. 03-ci-cd/README.md explains the pipeline, per the readme rules.
Action: Gate: actionlint clean. Every command the jobs run also passes locally. The workflow has not run on GitHub. That fact goes in the final report, not in the readme.
Status: OPEN
```

### Step 5. 04-terraform/

```
Issue:  Step 5. Build: AWS provider pinned, one small EC2 instance with the instance type as a variable, a security group that opens SSH only from a my_ip variable plus the app port, key pair name as a variable, outputs for the public IP and the SSH command, terraform.tfvars.example. State files and tfvars ignored by git. Folder readme per the readme rules.
Action: Gate: terraform fmt -check, init -backend=false and validate all pass. No plan. No apply.
Status: OPEN
```

### Step 6. 05-ansible/

```
Issue:  Step 6. Build one playbook with three roles: base (packages, service user, firewall), docker (engine install), app (run the image as a container, wait for /health). An inventory example that takes the IP from the Terraform output. Folder readme per the readme rules.
Action: Gate: ansible-lint clean, syntax check passes. Run the playbook against a local Ubuntu container. Tasks that cannot run inside a container (systemd, firewall, Docker engine) carry a tag and are skipped there. A second run reports zero changes. The skipped tasks are listed in the final report as lint verified only.
Status: OPEN
```

### Step 7. 06-kubernetes/ and the final root README

```
Issue:  Step 7. Build Namespace, ConfigMap for APP_VERSION, Deployment (2 replicas, readiness and liveness probes on /health, resource requests and limits, non-root security context), Service. Folder readme per the readme rules. Then rewrite the root README: what the repo is, a table of the folders with one line each, a Mermaid diagram of the path from code to running container, how to run each folder.
Action: Gate: manifests validate. On a local cluster: import the image, apply, rollout completes, /health answers through a port-forward, delete one pod and confirm it is replaced. Delete the cluster afterwards. If no local cluster tool is available: validate only, and say so.
Status: OPEN
```

### Other open items

```
Issue:  The main checkout holds an untracked .gitignore. Once the branch tracks .gitignore, git merge refuses to overwrite the untracked copy.
Action: The owner moves or deletes the untracked copy in the main checkout before merging. The exact commands go in the final report.
Status: OPEN
```

```
Issue:  The owner's exact readme wording for step 1 and the full text of the build instruction are not stored in this file. Copies sit in .tmp/sdd/ in the branch working folder, which is not tracked.
Action: If that folder is gone, the owner supplies the texts again.
Status: OPEN
```

## ACTIONS (dated log)

### 2026-11-12 Step 0. Preflight passed

```
Issue:  Step 0. Preflight, second run after the owner started Docker Desktop. Start 05:40, end 05:43 (+0200). The first run, 03:14 to 03:18, was blocked. See the entry below.
Action: All checks pass. Planned as live checks: the app, the shell scripts, the image, the Ansible run in a container, Kubernetes on a local cluster (k3d gets installed with winget when step 7 starts). Static checks only, by rule: Terraform (no plan, no apply), the CI workflow (not run on GitHub), and the Ansible tasks that need a real host.
Status: DONE
```

Gate evidence:

```
$ python --version
Python 3.14.3
$ git --version
git version 2.53.0.windows.3
$ docker version --format 'client={{.Client.Version}} server={{.Server.Version}} os={{.Server.Os}}/{{.Server.Arch}}'
client=29.8.2 server=29.8.2 os=linux/amd64
$ docker run --rm alpine:3.21 sh -c 'echo container-ok; uname -sm; cat /etc/alpine-release'
container-ok
Linux x86_64
3.21.10
$ df -h /c
C:              347G  233G  115G  67% /c
$ curl -s -o /dev/null -w 'pypi %{http_code}\n' https://pypi.org/simple/fastapi/
pypi 200
$ winget show --id k3d.k3d --exact --source winget
Found k3d [k3d.k3d]
Version: 5.9.0
Installer Type: portable
```

### 2026-11-12 Step 0 preflight for the build run

```
Issue:  Step 0. Preflight for the build run, steps 0 to 7. Start 03:14, end 03:18 (+0200).
Action: Pass: Python 3.14.3, git 2.53.0, free disk 115 GB, PyPI answers 200, Docker Hub registry answers 401 (reachable), winget offers k3d 5.9.0 and kind 0.33.0 as portable installs, kubectl is present. Fail: "docker version" prints "failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine". No Docker process is running and the WSL distro docker-desktop is stopped. Stopped as the stop rules require. No later step started.
Status: BLOCKED
```

### 2026-11-12 Owner answers

```
Issue:  The step 1 readme blocker and the question about the untracked .gitignore.
Action: The owner approved replacing the root readme and renaming it to README.md, set the work location, and set how .gitignore is handled. The owner also widened the scope to a full build run, steps 0 to 7. See DECISIONS.
Status: DONE
```

### 2026-11-12

```
Issue:  Preflight for step 1, the repo skeleton and the small app.
Action: Checked the stop conditions. Python 3.14.3 is present. No app/ folder exists. The root Readme.md is not empty, so work stopped before any build step. Created this ledger.
Status: DONE
```

## DECISIONS (locked log)

Entries set by the owner are FINAL. Entries decided alone during the build run are REVISIT, so the owner can review them.

### Portfolio shape

```
Issue:  How the portfolio is organized.
Action: One small app is carried through six folders: 01-linux-bash, 02-docker, 03-ci-cd, 04-terraform, 05-ansible, 06-kubernetes. Each folder adds one layer and can be run on its own. Set by the owner.
Status: FINAL
```

### App scope

```
Issue:  How much the app does.
Action: Deliberately trivial. It is the payload, not the subject. FastAPI with exactly two endpoints, /health and /version. No extra endpoints, no database, no auth. Set by the owner.
Status: FINAL
```

### Root readme replacement

```
Issue:  The repo root held a non-empty Readme.md with a broken paste of the app readme text.
Action: Rename it to README.md with git mv, then replace the content with the owner's root readme text. Approved by the owner.
Status: FINAL
```

### Work location for the build run

```
Issue:  Where the build run writes and how the work reaches main.
Action: All work stays on branch worktree-step-1-app in its own working folder. Nothing is written to the main checkout. No merge and no push. The owner merges. .venv lives in the root of the branch working folder. Applies until the owner merges the branch. Set by the owner.
Status: FINAL
```

### Git ignore file on the branch

```
Issue:  .gitignore was untracked and existed only in the main checkout.
Action: Create it on the branch from the main checkout copy, then add what each step needs. Existing lines stay untouched. Set by the owner.
Status: FINAL
```

### Hebrew in readme files

```
Issue:  How Hebrew sections treat technical terms.
Action: Full Hebrew sentences. Technical terms go in backticks. In the two readme texts the owner supplied for step 1, wrapping technical terms in backticks is the only wording change allowed. Set by the owner.
Status: FINAL
```

### Readme rules for folders 01 to 06

```
Issue:  Structure and voice of each folder readme.
Action: Sections in this order: What this is. Why it is built this way. How to run. What I would improve. English first, then a line with ---, then the same in Hebrew. First person, short plain sentences, like the app readme. No buzzwords, no marketing words, no em dashes. State only what was built and verified. No claim that anything ran on AWS or on GitHub. No statement that anything is free of charge. Readme files and commit messages describe the project only. They do not mention this file or the build instruction. Set by the owner.
Status: FINAL
```

### Tools and line endings

```
Issue:  How lint and build tools run, and which line endings the repo uses.
Action: Tools run as containers where possible (shellcheck, hadolint, actionlint, terraform, ansible, kubeconform). A host CLI is installed only with winget or scoop, and only without admin rights and without a reboot. A .gitattributes file forces LF for *.sh, Dockerfile, *.yml, *.yaml and *.tf, because this machine is Windows and the targets are Linux. Set by the owner.
Status: FINAL
```

### Limits for the build run

```
Issue:  What the build run must not do.
Action: No git push and no remote changes. No terraform plan, apply or destroy, and no command that creates or changes an AWS resource. No writes outside the branch working folder, except host installs under the winget or scoop rule. No admin elevation, no reboot, no system settings changes, no global pip installs. No reading, printing or committing of secrets, keys, tokens, or anything under ~/.aws and ~/.ssh. No extra app features. Set by the owner.
Status: FINAL
```

### Stop rules for the build run

```
Issue:  When the build run stops instead of continuing.
Action: Stop when preflight finds no working Docker, when a gate still fails after three real fix attempts, when a fix would break a limit, when a command asks for a password, admin elevation or a reboot, or when git state is unexpected (branch changed, main checkout modified, merge conflict). On a stop: commit what is safe, mark the step BLOCKED here, report, and do not start later steps. A gate is never weakened, a check is never deleted, and a step is never marked DONE without evidence. Set by the owner.
Status: FINAL
```

### First commit message reworded

```
Issue:  The first commit on the branch named this file in its message. The owner's rule is that commit messages describe the project only.
Action: Reworded it with git commit --amend while it was still the newest commit and unpushed. The content is unchanged. The hash changed from 6c7be4c to af8dda5. History is not rewritten again. Decided alone during the build run.
Status: REVISIT
```

### Shared names across folders

```
Issue:  The folders must agree on names, ports and versions.
Action: Planned values: app port 8000, local image name portfolio-app, container user UID 10001, service user appuser on Linux hosts, systemd unit and Kubernetes objects named portfolio-app, Kubernetes namespace portfolio, Python 3.14 in the venv, in the image and in CI. Decided alone during the build run.
Status: REVISIT
```
