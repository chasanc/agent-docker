---
name: fire-agent
description: Hand a task to the headless agent-docker Claude agent — either run it immediately in a container or arm it for the nightly 23:00 scheduled run. Accepts a plan .md file path or a plain-language description of the work (which gets drafted into a proper plan). Use when the user says "fire the agent", "schedule this for tonight", "have the agent do X", "run this in agent-docker", or wants to arm/queue a nightly task.
---

# Fire Agent (agent-docker)

`AGENT_DIR` is this repository's root (the directory that contains
`run-task.sh`). Do not hardcode a host path. Resolve it in order:

1. Use `$AGENT_DIR` if it is already set and `$AGENT_DIR/run-task.sh` exists.
2. Follow the skill symlink from the README:
   ```
   skill=$(readlink -f "$HOME/.claude/skills/fire-agent/SKILL.md")
   AGENT_DIR=${skill%/skills/fire-agent/SKILL.md}
   ```
   Confirm `$AGENT_DIR/run-task.sh` exists.
3. Otherwise ask where the clone lives.

Two channels — never mix them:

- **now** → `./run-task.sh <plan.md>` (parallel-safe; plan file stays put)
- **schedule** → arm as `next-task.md` / `task-queue/NN-*.md` (runs at 23:00, archived on success)

## 1. Parse the request

- **Plan source**: a path to an existing `.md` file, or free text describing the work.
- **Mode**: "now"/"immediately"/"start" → now. "tonight"/"schedule"/"23:00"/"queue" → schedule.
  If unstated, ask with AskUserQuestion: "Run now" vs "Schedule for tonight (23:00)".

## 2. If given free text, draft a plan file

Model it on `$AGENT_DIR/next-task.md.sample`. The container starts empty and has no
host skills and nobody to ask, so the plan must be fully self-contained:

- Repo access: `rm -rf /workspace/<repo> && gh repo clone <owner>/<repo> /workspace/<repo>`,
  then which branch to start from.
- Concrete steps and acceptance criteria (reference the Jira/Linear ticket if given —
  the agent can read it via the jira/linear MCP servers).
- Explicit guardrails, e.g. "Do NOT merge the PR", "Do NOT review your own PR".
- **One commit per PR.** Spell out the mechanic, because "commit once at the end"
  is the wrong fix — commits in the container bind mount are what survives a killed
  run: *"Commit in small increments as you work. Immediately before pushing, collapse
  them into a single commit: `git reset --soft "$BASE"` then one commit with the
  full message. Push one commit and open one PR."*
- **Never hardcode the base branch.** Repos differ (`main`, `develop`, ...), so have
  the plan derive it after cloning — `BASE=$(git rev-parse --abbrev-ref origin/HEAD)`
  — and open the PR with `gh pr create --base "${BASE#origin/}"`. Hardcode a base only
  when the user names one that is not the repo's default.

Show the drafted plan to the user and get a quick OK before arming/running it —
it will execute unattended with real credentials.

## 3a. Mode = now

1. If drafted from text, save it to `$AGENT_DIR/manual-plans/<yyyymmdd-HHMM>-<slug>.md`
   (gitignored; keeps a record). A user-provided file is used where it is.
2. From `$AGENT_DIR`, launch **in the background** (runs can take hours):
   `./run-task.sh <absolute-plan-path>`
   - Docker socket permission denied → retry as `sg docker -c './run-task.sh <path>'`.
3. Report the `Logging to .../logs/...` line so the user can tail it, and where
   results land (PR link, workspace, etc. per the plan).
4. Multiple "now" runs may overlap freely — each plan gets its own workspace
   directory. Only two simultaneous runs of the *same* plan file need a
   `<plan>.env` with a distinct `AGENT_WORKSPACE`.

## 3b. Mode = schedule

1. Nothing armed yet (`next-task.md` absent, no `task-queue/*.md`) → write the plan
   to `$AGENT_DIR/next-task.md`.
2. Something already armed → keep order explicit via the queue:
   - If `next-task.md` exists, move it to `task-queue/01-next-task.md` first
     (the queue runs before `next-task.md`, so leaving it would reorder).
   - Add the new plan as `task-queue/NN-<slug>.md`, NN = highest prefix + 1.
3. Per-task overrides (optional) go in a matching `.env` next to the plan:
   `AGENT_WORKSPACE=...`, `AGENT_ALLOWED_TOOLS=...`.
4. Confirm to the user: armed as `<file>`, fires tonight at 23:00 — the machine
   must be on and awake (if asleep, it catches up on wake).

## Notes

- Run armed plans early: `sudo systemctl start agent-docker.service`.
- Logs: `$AGENT_DIR/logs/<timestamp>-*.log`; completed scheduled plans move to
  `$AGENT_DIR/task-archive/`.
- Workspace: `~/agent-docker-workspace/<plan-slug>/` (printed as `Workspace:`
  at the start of each run) — kept for 7 days so a failed run can be inspected.
  Set `AGENT_WORKSPACE_RESET=1` in a `<plan>.env` to force a clean start.
- Default allowed tools: `Bash,Read,Glob,Grep,Edit,Write,WebFetch,mcp__jira,mcp__linear`.
