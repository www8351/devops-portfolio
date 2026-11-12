# LEDGER

Entry format:

```
Issue:  [what / why]
Action: [what was done or what is planned]
Status: [OPEN | IN PROGRESS | DONE | BLOCKED | FINAL]
```

## ISSUES (current state)

```
Issue:  Step 1 is blocked. The repo root holds a non-empty Readme.md (846 bytes, commit e9572ae). The step 1 instruction says to stop in that case.
Action: Owner decides. Proposed: rename the file to README.md with git mv and replace its content with the root readme text from the step 1 instruction.
Status: BLOCKED
```

```
Issue:  Step 1 build has not started. Scope: FastAPI app with /health and /version, pinned requirements, two tests, app readme, root readme, ".pytest_cache/" in .gitignore.
Action: Build, verify in .venv with pytest and one uvicorn run, commit app code first and both readme files second. Starts when the entry above is resolved.
Status: OPEN
```

```
Issue:  .gitignore is untracked. It exists only in the main working copy, so other branches and fresh clones do not have it.
Action: Owner decides whether to commit it. Step 1 only appends ".pytest_cache/" to it.
Status: OPEN
```

## ACTIONS (dated log)

### 2026-11-12

```
Issue:  Preflight for step 1, the repo skeleton and the small app.
Action: Checked the stop conditions. Python 3.14.3 is present. No app/ folder exists. The root Readme.md is not empty, so work stopped before any build step. Created this ledger.
Status: DONE
```

## DECISIONS (locked log)

No entries yet.
