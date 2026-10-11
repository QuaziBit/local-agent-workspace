# Delegating to Claude Code / Codex Through Hermes

One page, one job: how to actually make Hermes execute a delegation,
instead of just talking about it. This is the single most common
way a Hermes session goes sideways — not because delegation is
broken, but because the phrasing didn't trigger it.

## The core rule

Hermes's terminal tool only fires on an **explicit instruction to use
it**. A bare, conversational request — even one that clearly implies
you want a CLI run — gets reasoned about and answered in chat. It
does NOT get executed.

**The exact templates, every time:**

```
Use your terminal tool to run: claude -p "<task>"
```

```
Use your terminal tool with pty=true to run: codex exec --skip-git-repo-check "<task>"
```

Two details that are easy to drop and both matter:
- **`pty=true` is required for Codex, and must be OMITTED for Claude.**
  Backwards either way causes a hang, not an error — the opposite of
  a fast failure.
- **`--skip-git-repo-check`** is needed for Codex against any
  ephemeral/scratch directory (a real project with its own `git init`
  doesn't need it — see `agent_tier_operations.md`).

## Good vs. bad, side by side

| Won't execute (gets discussed instead) | Executes |
|---|---|
| "Try using claude to check the weather" | `Use your terminal tool to run: claude -p "what's a good way to check live weather from a script"` |
| "Can you get codex to look at this file" | `Use your terminal tool with pty=true to run: codex exec --skip-git-repo-check "summarize this file: ..."` |
| "Use claude for X" | `Use your terminal tool to run: claude -p "X"` |

The pattern: **name the tool, name the exact command, put the actual
task in quotes.** Anything softer reads as a request *to* Hermes, not
an instruction to delegate.

## Why the local model doesn't just "figure it out"

Hermes's own model (gemma4, local) reasons from its declared toolset.
If a request doesn't match a delegation trigger it recognizes, it
correctly treats the message as something to answer conversationally
— checking its skills list, noting what it can't do, and replying
honestly. That's the SAFE failure mode, not a bug: this project has
a documented case of the same local model doing the opposite —
fabricating a confident "result" for a delegation call rather than
admitting it couldn't complete it (see `local_models.md`). A clean
"I don't have that tool" beats a confident wrong answer every time.

## Delegating with a project mounted (`--project=<name>`)

Works on every Hermes chat/dashboard profile — ephemeral
(`hermes`/`hermes_claude`/`hermes_codex`/`hermes_all`) and the
persistent dashboards (`dashboard`/`dashboard_claude`/
`dashboard_codex`/`dashboard_all`) alike:

```
run.sh --project=<name> hermes_all
run.sh --project=<name> dashboard_all
```

The project mounts read-write at `/workspace`. Hermes's terminal
tool doesn't reliably pick up the container's own default working
directory, so **always add `workdir=/workspace`** to the delegation
instruction — the same reason `/opt/hermes` shows up as the
accidental cwd otherwise:

```
Use your terminal tool with workdir=/workspace to run: claude -p "<task>"
Use your terminal tool with workdir=/workspace and pty=true to run: codex exec --skip-git-repo-check "<task>"
```

Without a project mounted, Hermes can only see the vault — this is
the one way to give it real project access. See
`projects.md` for getting a project into
`~/workspace/projects/` in the first place.

**Dashboard-specific note:** the mount is fixed at launch — it's
part of *that instance's* configuration for as long as it stays up.
Switching projects means `run.sh down` then relaunching with a
different `--project=`, not something you can change mid-session.

## Writing outside the default cwd (confirmed)

`workdir=/workspace` (or wherever) alone isn't always enough for a
write to actually land — two things are needed together, confirmed
by direct verification (`docker exec ... cat <file>`), not by
trusting what Hermes said happened:

1. **`workdir=<target-dir>`** pointed directly AT the destination
   directory, not just "somewhere useful" — e.g.
   `workdir=/vault/agent_inbox`, not `workdir=/vault`.
2. **A relative filename**, not an absolute cross-mount path —
   `claude_test.txt`, not `/vault/agent_inbox/claude_test.txt`.

```
Use your terminal tool with workdir=/vault/agent_inbox to run: claude -p --permission-mode acceptEdits "write the text HELLO to claude_test.txt"
```

An absolute path — even with `workdir=` set AND
`--permission-mode acceptEdits` present — genuinely failed in
testing (verified by direct file check, not narration). Both pieces
together are what worked.

## The default working directory

Every Hermes profile — chat and dashboard — now starts in
`/vault/agent_inbox` by default (`working_dir:` in each compose
file), instead of `/opt/hermes`. This does NOT expand what's
writable — `HERMES_WRITE_SAFE_ROOT` is unchanged everywhere, still
exactly `/opt/data:/vault/agent_inbox` — it only changes where the
container starts, so a relative-path write lands in the right place
by default.

**This is a backstop, not a guarantee.** Hermes's terminal tool has
been found not to reliably pick up a container's own default
`working_dir` for delegated commands (see `local_models.md`'s
`/opt/hermes` cwd finding). Keep passing `workdir=/vault/agent_inbox`
explicitly in delegation instructions — that combination (explicit
`workdir=` + a relative filename) is the one confirmed, reliable
path; the new default just means you're more likely to be starting
from the right place even if you forget.

## Multi-command chains

Hermes's terminal tool errors on a raw top-level `&&`. Wrap any
multi-step delegation in one string:

```
Use your terminal tool to run: bash -c "cmd1 && cmd2 && cmd3"
```

## Remember what the CLIs actually are

Neither `claude -p` nor `codex exec` has live internet/weather/search
access by default — they're coding CLIs. Delegating "check the
weather" to either one, even with perfect phrasing, won't produce a
real answer unless the CLI's own settings grant it web access
separately. Right phrasing gets the command to RUN; it doesn't grant
the command capabilities it doesn't have.

**Hermes's own `web_search` (once `web.backend: "ddgs"` is
configured, see `hermes_operations.md` §10) is search-only — no
`web_extract`.** For weather, scores, prices, or anything else
"current" matters for, don't trust a `ddgs`-backed answer: it
answered a weather question with the wrong day's forecast because
there's no live-page read behind it, only whatever a search snippet
said. Verify time-sensitive answers against a real API/tool, the
same way any other delegated result gets verified below.

## Copy-paste examples: search + write, all three tools

Confirmed working, all three, host-verified with `cat` after each —
not narration. Swap the topic and filename, keep the shape.

### Local model — search, then write

Two separate messages. The write needs an EXPLICIT destination —
`write_file` has two valid roots (`/opt_data` and
`/vault/agent_inbox`) and silently picks one if you don't say which;
it will NOT ask.

```
Search for what the Landlock LSM is and how it's different from seccomp.
```
```
Write a file research/landlock_summary.md with a two-sentence summary of what you just found, to /vault/agent_inbox
```
```bash
cat ~/workspace/vault/agent_inbox/research/landlock_summary.md
```

### Claude — search, then delegate a write

One message or two both work — confirmed both ways. Needs
`--permission-mode acceptEdits` or it silently waits for an approval
nobody can give.

```
Search for what AppArmor is and how it differs from SELinux. Then use your terminal tool with workdir=/vault/agent_inbox to run: claude -p --permission-mode acceptEdits "write a short summary of AppArmor vs SELinux to research/apparmor_vs_selinux.md"
```
```bash
cat ~/workspace/vault/agent_inbox/research/apparmor_vs_selinux.md
```

### Codex — search, then delegate a write

Same shape, `pty=true` and `--sandbox workspace-write` both
required.

```
Search for what cgroups are used for in container isolation. Then use your terminal tool with workdir=/vault/agent_inbox and pty=true to run: codex exec --skip-git-repo-check --sandbox workspace-write "write a short summary of cgroups to research/cgroups_summary.md"
```
```bash
cat ~/workspace/vault/agent_inbox/research/cgroups_summary.md
```

### The one rule that covers all three

A search-then-write delegation has occasionally reported success —
in convincing, specific detail, right down to quoting the file's
supposed contents — while writing nothing at all. Same phrasing,
same tools, worked cleanly on a retry with no changes made. This
looks non-deterministic, not tied to any particular wording, so
there's no phrasing fix for it. The `cat` above is not a formality;
it is the only part of this that's actually true.

A later, more precisely-caught instance under `delegate_task`
(Additions, below) traced this to a specific trigger — a denied
path guess with no retry — and a concrete mitigation: always give
the full absolute destination path in the instruction. That
narrows the risk considerably but doesn't fully retire this
section's caution; verify by `cat`, always.

## Capturing a delegated answer (one turn, two steps)

Ask a question, then save the answer — the second step uses Hermes's
own `write_file` rather than asking the CLI to write it itself; more
reliable when the goal is just capturing an answer, not editing code:

```
Use your terminal tool to run: claude -p "summarize what this project does in 3 sentences"
```
```
Now write that summary as a file named summary.txt in /vault/agent_inbox
```

## Quick self-test

Not sure if a request will execute? Ask: does the message contain
the literal words "terminal tool" and a real `claude -p "..."` or
`codex exec ...` command? If not, expect a conversational reply, not
a delegation.

---
See also: `quick_reference.md` (the same templates in the full
command cheat sheet), `workflows.md` (delegation inside broader
task flows), `local_models.md` (the full debugging history behind
why these exact flags exist), `agent_tier_operations.md` (the
git-trust flag decision in more depth).


---

## Additions

### Subfolder writes (reports/, research/, sessions/)

**Subfolder writes (reports/, research/, sessions/):** keep
`workdir=/vault/agent_inbox` — the `.git` root that satisfies
Codex's trust check — and put the subfolder in the RELATIVE
filename: `"write the report to reports/foo.md"`. Setting
`workdir=` to the subfolder itself re-breaks the trust check
(no `.git` down there). Claude and `write_file` accept the same
relative-path form; one convention covers all three tools.

### Exit codes lie

**`codex exec` exits 0 even when the task failed.** Hermes
relaying "executed successfully" can be a truthful report of a
lying exit code. The only verdict is the file itself, host-side —
and if the file exists, confirm which tool wrote it (Hermes has
been observed silently substituting its own `write_file` for a
failed CLI delegation).

### A second delegation mechanism exists: `delegate_task` + skills

Some Hermes builds also expose a `delegate_task` tool with named
`skill` arguments (`'claude-code'`, `'codex'`) instead of — or
alongside — the plain terminal-tool pattern this doc otherwise
describes. It runs as an async background fan-out (chat stays
usable while it works, then reports "ASYNC DELEGATION BATCH
COMPLETE" with a live log path under
`/opt/data/cache/delegation/live/`). This showed up unannounced in
one session — likely because `hermes_all`'s Dockerfile pulls
`FROM nousresearch/hermes-agent:latest`, a floating tag, the same
category of risk that was the whole reason Codex got pinned to a
fixed version. Treat `nousresearch/hermes-agent` as an unpinned
dependency until it gets the same treatment.

**Confirmed, host-verified, on this mechanism specifically** (do
not assume it inherits the terminal tool's track record just
because it's the same underlying stack — verify separately):

- Honors `terminal.cwd` from `config.yaml` exactly like the plain
  terminal tool — no `workdir=` needed once that's set (see below).
  Confirmed separately on both `hermes_all` (ephemeral) and
  `dashboard_all` (persistent) — the dashboard needed the same
  container-recreate-after-config-edit step as everything else in
  this project that touches `config.yaml`.
- Both skills write real files with real content, independently
  confirmed with distinct filenames, on both profile forms.
- A search-then-delegate chain through `delegate_task` produces
  real content matching the search, not a fabrication — tested
  after the exact same phrasing pattern intermittently fabricated
  once on the plain terminal-tool path, so this isn't assumed safe
  by association.
- Routes through the SAME `write_file` enforcement as everything
  else — a `delegate_task` write outside `agent_inbox` fails with
  the identical `Write denied: '...' is outside
  HERMES_WRITE_SAFE_ROOT (/opt/data:/vault/agent_inbox)` message
  seen from the plain terminal tool. One boundary, one set of
  rules, regardless of entry point. Confirmed both by the chat
  narration AND by reading the raw delegation transcript directly
  (`/opt/data/cache/delegation/live/<id>/task-0.log` inside the
  container) — the log showed one denied `write_file` call and an
  honest failure report, no discrepancy.

**The named skill is a routing hint, not a guarantee of which
mechanism executes.** Asking for the `'codex'` skill on a plain
file-write goal has been observed satisfying the goal via
`write_file` directly, with `codex exec` never invoked at all —
confirmed by reading the raw transcript, which showed only
`write_file` tool calls. A file landing successfully under a named
skill does not by itself prove that CLI ran; if the point of a test
is specifically to exercise the CLI binary, verify from the
transcript, not from the file's mere existence.

**`write_file`'s own relative-path resolution is separate from
`terminal.cwd`.** A delegated subagent given a bare relative
filename can still have `write_file` resolve it against `/opt/hermes`
(Hermes's own install dir) rather than the configured
`terminal.cwd` — seen directly in a transcript's first (denied)
attempt before a self-correction to the full path succeeded.
`terminal.cwd` governs the terminal tool's shell; it does not
change where `write_file` looks by default. For anything delegated
via `delegate_task`, give the FULL absolute path in the instruction
rather than relying on either default.

**A fabrication was caught, precisely characterized, and reproducibly
avoided.** One subagent's own relative-path guess for a target file
was denied (resolved against `/opt/hermes`); rather than retrying
with a corrected path — the way a successful case in the same
session genuinely did — it claimed the file was written and even
described content as if reviewed. The target file never existed.
Caught only by reading the raw transcript directly: one denied
`write_file` call, then a jump straight to a completion claim with
no second tool call in between. The trigger looks precise: it
happened specifically when the subagent's own default path guess
got denied and it had discretion over what to try next. Giving the
exact, correct absolute path in the delegation instruction up front
— so there's no wrong guess to be denied in the first place —
produced a clean, verified success on an identical task shape
immediately after. Not proof this can never happen with a correct
path from the start, but a concrete, actionable way to reduce the
odds: **don't let a delegated subagent guess its own write path.**

**Usage:**
```
Use delegate_task with the 'claude-code' skill to <task>
Use delegate_task with the 'codex' skill to <task>
```
For any task where the deliverable is a specific file, spell out
the full absolute path in the instruction itself — do not phrase
the task around a bare filename and let the subagent infer where
it goes.

**Confirmed reliable, both profile forms:** a search-then-write
instruction that names the full absolute destination path up front
(e.g. `"...write a summary to the exact absolute path
/vault/agent_inbox/reports/<name>.md"`) has produced clean, correct,
verified results consistently.

**Not yet tested under this mechanism:** offline/hang behavior —
`config.yaml`'s `terminal: timeout: 180` may or may not bound a
hung `codex exec`/`claude -p` the way manual `timeout 15 ...`
wrapping does for the plain terminal tool. Don't assume it's safe
to skip the manual wrap until this is checked.

### `terminal.cwd` in config.yaml — stop passing `workdir=` every time

`~/.secrets/hermes-home/config.yaml` has a `terminal:` block with
its own `cwd:` key, defaulting to `.` (relative — resolves
somewhere unpredictable depending on the container's own state,
and triggers a "TERMINAL_CWD... deprecated" warning if an older
`.env`-based override was ever set). Point it at the vault inbox
directly:

```yaml
terminal:
  backend: local
  cwd: /vault/agent_inbox
  timeout: 180
  ...                      # leave every other key under terminal: as-is
```

Takes effect on the NEXT launch, not the current session — exit and
relaunch after editing. Once set, confirmed working for both
delegation mechanisms above: a bare
`Use your terminal tool to run: bash -c "..."` with no `workdir=`
at all lands correctly in `agent_inbox`, host-verified. This doesn't
change `HERMES_WRITE_SAFE_ROOT` or any write permission — it only
changes where a relative write lands by default. Subfolder writes
and `--project` sessions still need their own explicit `workdir=`
override as documented elsewhere in this doc.
