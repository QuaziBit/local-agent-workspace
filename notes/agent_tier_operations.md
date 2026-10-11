# Agent Tier Operations (dev / docs / review / sandbox)

Companion to `hermes_operations.md` — that doc covers the six Hermes
profiles (a local model driving delegation); this one covers the
four agent profiles, where you drive `claude` and `codex` directly
inside a container. Fully verified post-rebuild — see
the archived `_archive/testing_plan.md` section 1.7 for the staged test session this was
written from.

## 1. The four profiles, and when to use each

| Profile    | Project mount | Network        | Vault              | Use for |
|------------|---------------|-----------------|---------------------|---------|
| `sandbox`  | none (own `projects/sandbox` only) | on | none at all | throwaway experiments, first image build |
| `dev`      | read-write    | on              | full curated set + `agent_inbox` rw | real project work |
| `docs`     | read-write    | **none**        | full curated set + `agent_inbox` rw | offline file/doc editing |
| `review`   | **read-only** | **none**        | full curated set + `agent_inbox` rw | reading/auditing a project without risk of touching it |

Both CLIs (Claude Code, Codex) are installed in all four — same
shared `docker/agent` image — but `docs` and `review` cannot
actually USE them (see section 3). Same underlying image build
across all four means only the FIRST profile you ever run pays the
build cost; the rest reuse the cached layers (confirmed: a "build"
on an already-built image completes in ~1 second).

## 2. The secrets-env guard (dev.yaml only)

`dev.yaml` requires `${SECRETS_DIR}/${PROJECT}.env` to exist
(`env_file:` in the compose file) — `docs`/`review`/`sandbox` don't
have this requirement. `run.sh dev <project>` checks for it before
invoking compose and refuses with a clear, actionable message if
it's missing:

```
dev.yaml declares env_file $SECRETS_DIR/hello_test.env and it doesn't exist.
Create it first (empty is fine):  touch /home/<user>/.secrets/hello_test.env
```

Confirmed behavior, not a bug — `touch` the file (empty is fine
unless the project actually needs env vars) and re-run.

## 3. Mount boundaries — confirmed, with the "failure is the pass" cases

The full boundary sweep, run against `dev` (the most permissive
profile) and `review` (the least):

- `/workspace` — read-write on `dev`/`docs`, **read-only on
  `review`** (`touch` there returns "Read-only file system" — that
  IS the pass, not an error to chase)
- `/vault/agent_inbox` — writable on ALL FOUR profiles, including
  `review` — the one designated output path even when the project
  itself is locked
- `/vault/programming`, `/security`, `/research`, `/ideas`,
  `/projects`, `/archive` — read-only everywhere ("Read-only file
  system" is correct)
- `/vault/personal` — does not exist on any profile ("No such file
  or directory" is correct — never mounted, not even read-only)
- `/ai` — read-only everywhere
- `sandbox` has **no `/vault` at all** — "No such file or
  directory," by design (no vault access whatsoever for throwaway
  work)

Ownership: files written from inside any container land on the
host owned by the real user (confirmed `alexm:alexm`, not root) —
the `UID=1000`/`GID=1000` build args doing their job.

## 4. Network isolation (docs, review)

`network_mode: "none"` on both — confirmed by `curl -m 5
https://example.com` failing immediately ("Could not resolve
host"). This means **`claude` and `codex` cannot function at all**
in these two profiles — not degraded, non-functional. That's the
intended design: `docs`/`review` are for offline file work; the
moment a task needs AI assistance, that's what `dev` is for.

**Real finding: `claude -p` does NOT fail fast when
offline.** Unlike `curl`'s clean, instant DNS failure, a bare
`claude -p "hi"` inside `docs` hung indefinitely with no visible
progress and required a manual `Ctrl+C` to break (`Execution error`
was the only output, after the interrupt). No built-in timeout of
its own. **Practical consequence: any script or automation that
might invoke Claude Code in a context where network isn't
guaranteed should wrap it defensively** — e.g. `timeout 15 claude -p
"..."` — rather than trusting it to fail quickly on its own. Codex
wasn't separately tested offline this session; treat it with the
same caution until proven otherwise.

## 5. Getting AI CLIs to actually write files (dev)

Both CLIs default to a stance that blocks non-interactive writes —
confirmed real, not theoretical, from the first actual work task run
on this tier:

- **Claude Code**: plain `claude -p "<task involving a file write>"`
  stalls asking for write approval, with no way to grant it in
  non-interactive (`-p`) mode — it just sits there. Fix:
  `claude -p --permission-mode acceptEdits "<task>"`. Confirmed
  working: a real `README.md` was created and correctly owned on
  the host. **This applies to Hermes-delegated Claude write tasks
  too** — Hermes's terminal tool is exactly this non-interactive
  situation, so any Hermes → Claude call meant to change files needs
  the same flag.
- **Codex**: `codex exec` defaults are less consistent (see
  `local_models.md`'s sandbox-mode correction) — don't assume write
  access. Pass `--sandbox workspace-write` explicitly on any call
  meant to change files.
- **Ping/read-only tasks on either CLI**: no flags needed, confirmed
  working plainly.

## 6. Codex's git-trust requirement on this tier

Real project directories (created via `git init` once, as part of
normal project setup — see `reference/getting_started.md`'s AGENTS.md-copy
step) already satisfy Codex's trust check — neither `git init` nor
`--skip-git-repo-check` is needed for delegation calls against a
real project under `dev.yaml`. The flag matters for throwaway,
non-repo scratch work (`sandbox`, or ephemeral Hermes scratch
dirs) — see `local_models.md`'s "Codex git-trust pattern" section
for the full decision.
