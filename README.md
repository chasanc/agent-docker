# agent-docker

A Docker image running the Claude Code CLI headlessly, plus a system-level
systemd timer that checks every evening at 23:00 whether a task is armed.

## Daily workflow: arm-and-fire

The timer fires daily, but the run is a no-op unless you've armed a task.
To arm a task:

1. Write the task plan (the prompt) to `next-task.md` in this directory.
2. Optionally create `next-task.env` alongside it to override defaults, e.g.:
   ```
   AGENT_WORKSPACE=/path/to/some-repo
   AGENT_ALLOWED_TOOLS=Bash,Read,Glob,Grep,Edit,Write,mcp__jira
   ```
3. Leave the machine on and awake (lock is fine). At 23:00 the agent runs
   the plan; on success both files are archived to `task-archive/` with a
   timestamp and nothing runs again until you arm a new `next-task.md`.

On failure the plan stays armed and retries the next evening at 23:00.
If the machine is asleep at 23:00 with a task armed, the run catches up
as soon as the machine is next awake (`Persistent=true`).

### Investigating a run: logs

Every run (armed, queued, or manual) writes the container's full output to
`logs/<timestamp>-<plan-name>.log` (manual runs: `...-manual.log`).
Containers are started with `--rm`, so `docker logs` is gone after a run —
these files are the record. The same output also lands in the journal
(`journalctl -u agent-docker.service`) for timer-triggered runs.

For turn-by-turn tool-call detail, pass extra claude flags via
`AGENT_CLAUDE_ARGS` — e.g. put `AGENT_CLAUDE_ARGS=--verbose` in the
environment (or set it in the service unit) for the next run.

### Model

Runs default to `--model sonnet` (always the latest Sonnet). Override
per run with `AGENT_MODEL` (e.g. `AGENT_MODEL=opus ./run-task.sh plan.md`)
or via a `--model` flag in `AGENT_CLAUDE_ARGS`, which takes precedence.

### AWS credentials

The image ships the AWS CLI v2 (`aws`), and both runners mount the host's
`~/.aws` **read-only** at `/home/agent/.aws`. Nothing is baked into the image
and no AWS secret goes into `.env` — profiles and region config come straight
from the host files, so `aws s3 ls`, `aws sts get-caller-identity` etc. work
inside the container as they do on the host.

Selectors that *are* `.env` entries (they only name a profile/region, they are
not secrets):

```
AWS_PROFILE=default
AWS_REGION=your-region
```

Two shell-environment switches on the runner control the mount itself (like
`AGENT_DOCKER_CONTEXT`, these are read by the scripts, not from `.env`):

| Variable | Default | Effect |
|---|---|---|
| `AGENT_MOUNT_AWS` | `1` | `0` withholds AWS access entirely for that run |
| `AGENT_AWS_DIR` | `$HOME/.aws` | mount a different credentials directory |

(`AGENT_DETACH` is a third such switch, read by `run-task.sh` — see
[Detached runs](#detached-runs---detach---d--agent_detach1). It is also
honoured from a plan's `.env`, unlike the two above.)

If the directory does not exist, the mount is simply skipped — the run still
works, `aws` just has no credentials.

> **Scope the identity.** This container runs unattended with `Bash` allowed, so
> whatever the mounted profile can do, the agent can do. Use an IAM identity
> scoped to what the agent actually needs — ideally a dedicated agent profile
> pointed at by `AGENT_AWS_DIR`, not your own admin credentials.
>
> Also note `~/.aws/config` may not set a `region`; regional commands then need
> `AWS_REGION` in `.env` or an explicit `--region`.

### Manual runs: a separate channel (`run-task.sh`)

Manual and scheduled runs are deliberately separate. `run-nightly.sh`
(the timer) only ever executes armed plans; `./run-task.sh` runs a task
**right now** and never touches `next-task.md` or `task-queue/` — so a
manual run can never end up scheduled, and an armed plan is never
consumed by accident.

```
./run-task.sh path/to/my-plan.md          # run this plan immediately
./run-task.sh -d path/to/my-plan.md       # ...detached from this shell
AGENT_TASK_PROMPT="..." ./run-task.sh     # or a one-off inline prompt
```

#### Detached runs (`--detach` / `-d` / `AGENT_DETACH=1`)

By default the container is attached: the `docker run` client is a child of
your shell, and an attached client **forwards SIGINT/SIGTERM to PID 1 inside
the container** — so closing the terminal, or anything that kills the parent
(a supervising agent session, a `Ctrl-C` in the wrong window), takes the
agent down mid-run. Committed work survives in the workspace bind mount, but
an unpushed branch and an unopened PR do not.

`--detach` (or `-d`, or `AGENT_DETACH=1` in the environment or in a plan's
`.env`) starts the container with `docker run -d`, so the daemon owns it and
nothing that happens to the launching shell can signal it. `run-task.sh`
returns as soon as the container is up and prints the container name plus the
follow/status/stop commands. A `setsid nohup` streamer keeps writing the same
`logs/…` file, appends the container's exit code when it finishes, and then
removes the container — so `--rm` is deliberately omitted in this mode.

Trade-off: you no longer get the run's output on your terminal, and a failure
is only visible in the log file, so `tail -f` it if you want to watch. Use
attached for short interactive runs, detached for anything long.

The plan file can live anywhere (it is NOT moved or archived — reuse it
as often as you like). A matching `my-plan.env` next to it is sourced for
that run (`AGENT_WORKSPACE`, `AGENT_ALLOWED_TOOLS`, ...). Output is teed
to `logs/` like every run.

Manual runs are parallel-safe: start as many as you like, including while
a scheduled run is executing — each gets a unique container, log file and
workspace directory. Caveat: the workspace is keyed on the plan filename so
re-runs reuse their checkout, which means two runs of the *same* plan at the
same time still want an explicit `AGENT_WORKSPACE` for one of them.

Scheduled runs, by contrast, are serialized: a lock file ensures only one
armed-plan run executes at a time (a second start — e.g. racing the
23:00 timer — prints a message and exits). If you want an armed plan to
run *early* rather than at 23:00, trigger the scheduled channel itself:
`sudo systemctl start agent-docker.service`.

### Firing from Claude Code: the `/fire-agent` skill

A Claude Code skill wraps both channels. It **lives in this repo**, at
[`skills/fire-agent/SKILL.md`](skills/fire-agent/SKILL.md), so the launch
conventions are versioned next to the runner they drive — in particular the
plan-drafting rules (self-contained plan, one squashed commit per PR, no
self-review, don't merge). Claude Code loads it from `~/.claude/skills/`, so
link it once:

```bash
mkdir -p ~/.claude/skills/fire-agent
ln -s "$PWD/skills/fire-agent/SKILL.md" ~/.claude/skills/fire-agent/SKILL.md
```

A symlink rather than a copy: editing the skill and committing it are then the
same action, and the two can't drift. The skill resolves `AGENT_DIR` from that
symlink (the repo root that contains `run-task.sh`), so it stays portable.
Nothing here depends on the skill — everything it does is available directly
through `run-task.sh` and the arming files.

In any Claude Code session, say `/fire-agent <plan.md path or a sentence
describing the work>` — it drafts a self-contained plan if you gave only
a sentence (drafted plans are kept in `manual-plans/`), asks now-vs-tonight
if you didn't say, then either launches `run-task.sh` in the background or
arms the plan (using `task-queue/` ordering when something is already
armed).

Call examples, one per scenario:

```text
# 1. Existing plan file, run immediately
/fire-agent run manual-plans/fix-login-redirect.md now

# 2. Existing plan file, schedule for tonight's 23:00 run
/fire-agent schedule task-queue-drafts/upgrade-deps.md for tonight

# 3. Free-text task, run immediately (a plan is drafted and shown for OK first)
/fire-agent now: clone your-org/website, fix the broken sitemap generation
on develop, open a PR — do NOT merge it

# 4. Free-text task, schedule for tonight
/fire-agent tonight: work through ABC-1187 follow-ups in example-service and
open one PR per fix

# 5. Ticket-driven task (agent reads the ticket via the jira/linear MCP)
/fire-agent have the agent implement Jira ticket ABC-421 tonight

# 6. Mode left unstated — the skill asks "Run now" vs "Schedule for tonight"
/fire-agent clean up dead feature flags in your-org/backend

# 7. Add a second task to an evening that already has one armed
#    (existing next-task.md is moved to task-queue/01-..., this becomes 02-...)
/fire-agent also schedule for tonight: regenerate the API client after
the flag cleanup lands

# 8. Task with per-task overrides (written to a matching .env next to the plan)
/fire-agent tonight, with AGENT_WORKSPACE=~/agent-ws-etl and Task added to
AGENT_ALLOWED_TOOLS: refactor the three ETL repos in parallel subagents

# 9. Two immediate runs touching the SAME repo — ask for separate workspaces
/fire-agent run these now in parallel with separate workspaces:
manual-plans/fix-header.md and manual-plans/fix-footer.md
```

`/fire-agent` is conversational — these phrasings aren't rigid syntax, just
the signals the skill parses: a `.md` path or free text for the plan, and
"now"/"immediately" vs "tonight"/"schedule"/"queue" for the channel.

### Multiple tasks: the queue

For more than one task in an evening, put plans in `task-queue/` named for
their order — `01-refactor.md`, `02-tests.md`, ... They run **sequentially**
in filename sort order, each in its own fresh container, each archived
individually on success. Per-task overrides go in a matching env file
(`01-refactor.env` with `AGENT_WORKSPACE=...` etc.). If a task fails, the
queue stops there: the failed plan and everything after it stay armed and
retry the next evening (fix or delete the failed plan to unblock; completed
tasks never re-run). `next-task.md`, if present, runs after the queue.

Sequential is deliberate: tasks often build on each other, and one agent at
a time keeps API rate limits and repo state predictable. If you want
parallelism *within* one task (e.g. "fix these three independent repos"),
put it in a single plan and add `Task` to that plan's
`AGENT_ALLOWED_TOOLS` — Claude Code then fans out subagents itself inside
the container.

### Example task plan: implement a Jira ticket end-to-end

See `next-task.md.sample` — copy it to `next-task.md` (or into
`task-queue/`), adjust the ticket/repo, and it's armed. It encodes the
typical "implement ABC-xxx, open a PR" plan, with two important
adaptations vs. how you'd phrase this interactively:

- **Clone fresh inside the container** instead of mounting your live
  checkout — the agent works on a clean copy of the default branch, and your local
  working tree (branch, uncommitted changes) is untouched. The clone works
  because `GITHUB_TOKEN` is wired into git's HTTPS auth.
- **Spell every step out** — host-side skills and slash commands
  don't exist in the container; the equivalent is explicit instructions.

The plan stops at an open PR. Reviewing it is a human's job, so don't ask
the agent to review its own work or post review comments — a self-review
from the author of the diff adds noise to the thread and gives false
assurance to whoever reviews it next.

**One commit per PR, squashed at the end — not one commit from the start.**
Incremental commits are what survives an interrupted run (they sit in the
workspace bind mount and can be recovered or resumed); a run told to commit
only once at the end and killed at hour three leaves nothing behind. So the
plan asks for increments while working and a `git reset --soft "$BASE"`
into a single commit immediately before the push. The reviewer still gets
one diff.

`next-task.md`:

```markdown
Read Jira ticket ABC-123 (jira MCP) — it contains the full spec.

Clone the repo (removing any leftover from a previous run first):
`rm -rf /workspace/example-service && gh repo clone your-org/example-service /workspace/example-service`
(replace owner/repo), cd into it — you are on the repo's default branch.

Record the base: `BASE=$(git rev-parse --abbrev-ref origin/HEAD)` (e.g.
origin/develop). If features merge somewhere else, set BASE to that.

Create a feature branch named after the ticket and implement it per its
acceptance criteria. Commit in small increments as you work.

Immediately before pushing, collapse them into a single commit:
`git reset --soft "$BASE"`, then one commit referencing ABC-123.
One commit per PR.

Push the branch and open a Pull Request with `gh pr create --base "${BASE#origin/}"`,
summarizing what was implemented and referencing ABC-123.

Do NOT merge the PR, and do NOT review it or leave review comments on it —
review is a human's job. Stop once the PR is open.
```

No `next-task.env` needed for this pattern (the clone lives in the task's
own workspace). If you'd rather mount your local checkout instead,
set `AGENT_WORKSPACE=/path/to/example-service` — but then make
sure your working tree is clean, and expect the repo to be on the feature
branch the next morning.

## Workspaces

The runner owns *where* the workspace lives and *when* it is cleaned up; the
plan owns *what* goes inside it. Each task gets its own directory, mounted at
`/workspace` in the container:

```
~/agent-docker-workspace/          # AGENT_WORKSPACE_ROOT
  01-fix-sitemap/                  # one task — mounted at /workspace
    .agent-workspace               # marker: created by the runner
    example-service/               # the plan's clone
  manual-refactor-etl/             # a ./run-task.sh plan
```

Scheduled tasks are keyed on the plan filename, manual runs on the plan
filename prefixed with `manual-`, so re-running a plan reuses its checkout and
two different tasks can never wipe each other's.

Cleanup is by retention, not by delete-on-exit: a failed run's tree is worth
inspecting, and since a failed plan stays armed it re-clones on the next
attempt anyway. Before each run the runner deletes task workspaces untouched
for more than `AGENT_WORKSPACE_RETENTION_DAYS` (default 7). **Only directories
carrying the `.agent-workspace` marker are ever removed** — anything else under
the root, and any explicit `AGENT_WORKSPACE`, is left alone.

| Variable | Default | Effect |
|---|---|---|
| `AGENT_WORKSPACE` | — | Explicit dir for this task, used verbatim. Never auto-pruned. |
| `AGENT_WORKSPACE_ROOT` | `$HOME/agent-docker-workspace` | Where per-task dirs are created. |
| `AGENT_WORKSPACE_RETENTION_DAYS` | `7` | Prune age; `0` disables pruning. |
| `AGENT_WORKSPACE_RESET` | `0` | `1` empties the workspace before the run. |

`AGENT_WORKSPACE_RESET` deletes from *inside* a container against `/workspace`,
so the blast radius is the bind mount — a mistyped `AGENT_WORKSPACE` cannot
take a real host directory with it. Keeping `rm -rf /workspace/<repo> &&
gh repo clone ...` in the plan is still fine (and is what the sample does):
it is a reset-before-clone, and the plan is the only thing that knows the repo.

## One-time setup

1. `cp env.sample .env` and fill in the values. Scope every token to only
   what the agent needs — it runs unattended:
   - Claude auth needs no API key: run `claude login` on the host once;
     `run-nightly.sh` mounts the resulting OAuth credentials file read-only
     into the container.
   - `GITHUB_TOKEN` — a PAT scoped to the repos this agent needs. `gh` picks
     it up from the environment directly, and `entrypoint.sh` additionally
     rewrites `https://github.com/` to an `x-access-token` URL so plain
     `git clone`/`push` authenticate too. (Note: `gh auth login --with-token`
     deliberately is NOT called — it exits 1 when `GITHUB_TOKEN` is set.)
   - `JIRA_BASE_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` — Jira access via
     the `mcp-atlassian` MCP server (API-token auth, not the OAuth flow
     your interactive session uses — that flow needs a browser and can't
     run unattended). Generate the token at
     id.atlassian.com/manage-profile/security/api-tokens.
   - `LINEAR_API_KEY` — Linear access via the `@tacticlaunch/mcp-linear`
     MCP server (installed globally in the image), same reasoning:
     token-based, not OAuth. `mcp.json` maps it to the `LINEAR_API_TOKEN`
     env var the package expects. Generate the key in Linear under
     Settings > API.
2. Test it manually first:
   `AGENT_TASK_PROMPT="Say hello" ./run-task.sh`
3. Install the system Docker engine (one-time; see the "Two Docker engines"
   section for why): `sudo ./install-docker-ce.sh`, then re-login (or
   `newgrp docker`) so your shell can use it without sudo. (Pass
   `--with-timer` to do step 4 in the same run.)

   Works out of the box on Debian and Ubuntu and their derivatives. Docker
   publishes apt repos only for upstream releases, so the script resolves
   your release to the upstream codename it's built from — `kali-rolling` →
   `trixie`, Devuan `daedalus` → `bookworm`, Mint `wilma` → `noble` — and
   verifies that repo exists before writing the apt source. If your distro is
   too exotic (or on Debian `sid`, which Docker doesn't publish), it says so
   and you can force the choice: `DOCKER_APT_CODENAME=bookworm
   sudo -E ./install-docker-ce.sh`. `DOCKER_APT_DISTRO=debian|ubuntu`
   overrides the repo family the same way.
4. Install the systemd timer (system-level, not user-level, so it runs
   regardless of whether you're logged in). `systemd/agent-docker.service`
   ships with `User=` and the paths as placeholders, since they differ per
   machine — the installer fills them in from the checkout location and the
   invoking user:
   ```
   sudo ./install-docker-ce.sh --with-timer
   ```
   Running the installer without `--with-timer` prints the equivalent manual
   commands with your real paths already substituted, if you'd rather place
   the unit yourself.
5. Check it's scheduled: `systemctl list-timers agent-docker.timer`
6. Check a run's logs: `logs/<timestamp>-<plan>.log` in this directory,
   or `journalctl -u agent-docker.service`

## Two Docker engines: docker-ce (agent) + Docker Desktop (interactive)

The agent runs on **docker-ce** (the system engine), installed alongside
Docker Desktop via `sudo ./install-docker-ce.sh`. Rationale: Docker Desktop's
daemon only exists while you're logged in with Docker Desktop running, so a
scheduled system unit can't rely on it — and its file-sharing list can block
mounts outside your home directory. docker-ce starts at boot, runs with nobody
logged in, and mounts any path.

How the two coexist:
- `docker --context default` → docker-ce (`/var/run/docker.sock`), used by
  `run-nightly.sh` (override with `AGENT_DOCKER_CONTEXT=desktop-linux` to
  test on Docker Desktop).
- `docker --context desktop-linux` → Docker Desktop, your interactive
  workflow, unchanged (including its running containers).
- Images/containers are NOT shared between the engines. The agent image is
  rebuilt automatically on first docker-ce run. The Docker Desktop GUI
  cannot show or manage docker-ce — use `docker --context default ps -a`
  (or the VS Code Docker extension, which understands contexts).

## Important caveat: suspend/sleep

systemd timers only fire while the machine is powered on and awake. A
laptop asleep at 02:00 will NOT wake itself to run this — the `Persistent=true`
setting just means it catches up once you next resume/boot, not that it
runs on schedule. If you need it to run at an exact time overnight:
- Keep the laptop plugged in and awake overnight, or
- Configure an RTC wake alarm (`rtcwake`) before suspend — laptop hardware
  support for this is inconsistent, verify it actually wakes the machine
  before relying on it, or
- Run this on a machine/server that stays on (e.g. a cloud instance),
  which is the reliable option if the schedule matters.

## Design notes

- **The Claude credentials mount is read-only on purpose.** A token refresh
  inside the container dies with the container and is never written back to
  the host. Interactive use on the host keeps the token fresh; if headless
  auth starts failing after weeks of no interactive use, that's why.
- **`mcp.json` is baked into the image** (a `COPY` in the Dockerfile) rather
  than bind-mounted, because Docker Desktop's file-sharing list can refuse
  mounts outside your home directory. It holds no secrets — it uses `${VAR}`
  expansion from the container environment, populated from `.env`. Each run
  rebuilds the image, so edits are picked up on the next run.
- **Workspaces live under `$HOME/agent-docker-workspace`** (auto-created)
  for the same file-sharing reason, one directory per task; `AGENT_WORKSPACE`
  overrides it. See [Workspaces](#workspaces).
- **Workspace cleanup belongs to the runner, not the plan.** Plans come and
  go and cannot be trusted to tidy up after a crash; the runner prunes by
  retention instead, and any destructive wipe runs inside the container so it
  cannot reach past the bind mount.
- **Jira and Linear use API-token MCP servers, not OAuth.** The OAuth flows
  need a browser and cannot run unattended.
- **Headless runs approve no tools by default**, so the runners pass
  `--allowedTools` explicitly (override with `AGENT_ALLOWED_TOOLS`).
- **systemd timers do not wake a sleeping machine** — see the suspend/sleep
  caveat above.

## Roadmap

- Optional second agent CLI (`AGENT_CLI=claude|cursor`) behind an adapter.
  Not implemented.

## Files

- `Dockerfile` — Node + Claude Code CLI image, runs as your host UID/GID.
  Also installs `gh`, `git`, AWS CLI v2, `mcp-atlassian` (pipx), and
  `@tacticlaunch/mcp-linear` (npm).
- `entrypoint.sh` — configures GitHub auth from `GITHUB_TOKEN`, then execs `claude`.
- `mcp.json` — MCP server config for Jira (`mcp-atlassian`) and Linear,
  baked into the image at build time (no secrets in it — it uses `${VAR}`
  expansion from the container's env, populated from `.env`). Rebuild
  (automatic on each `run-nightly.sh` run) picks up edits.
- `run-nightly.sh` — the SCHEDULED runner (invoked by the timer): builds
  the image and runs the armed plan(s), archiving each on success.
- `run-task.sh` — the MANUAL runner: runs one plan file (or
  `AGENT_TASK_PROMPT`) immediately; never reads or archives armed plans.
- `workspace-lib.sh` — workspace lifecycle shared by both runners: per-task
  directories, retention pruning, opt-in reset (see [Workspaces](#workspaces)).
- `skills/fire-agent/SKILL.md` — the `/fire-agent` Claude Code skill that
  drives both runners; symlink it into `~/.claude/skills/fire-agent/` (see
  [Firing from Claude Code](#firing-from-claude-code-the-fire-agent-skill)).
- `next-task.md.sample` — template plan: clone, implement, one squashed
  commit, open a PR, stop (no self-review, no merge).
- `logs/` — one log file per run (created automatically, gitignored-worthy).
- `env.sample` — template for `.env` (gitignored).
- `systemd/` — unit files to install into `/etc/systemd/system/`.
- `LICENSE` — MIT.

## Note on Jira/Confluence scope

`mcp-atlassian` also supports Confluence via `CONFLUENCE_URL` /
`CONFLUENCE_USERNAME` / `CONFLUENCE_API_TOKEN` env vars if you want that
too — it is deliberately not wired up here, to keep the default token
scope as narrow as possible.

## License

MIT — see [LICENSE](LICENSE).
