# Doc entries — Codex sandbox saga closure

Paste-ready blocks for the three docs. Trim freely; every claim
is backed by host-verified evidence from the investigation
sessions.

---

## 1. features.md — move the laptop-mystery entry to **Resolved**

### Resolved: Codex-via-Hermes write failures (both machines) — root-caused and fixed

The "laptop mystery" (Codex writes failing via Hermes despite the
git-trust fix) is closed, and it turned out to be TWO stacked causes,
neither machine-specific in the way originally assumed:

1. **Daemon seccomp blocked user namespaces.** Codex's
   `--sandbox workspace-write` on Linux is bubblewrap, which must
   create an unprivileged user namespace — and the docker daemon's
   default seccomp profile blocks that on BOTH machines (proven:
   `unshare -U` → "Operation not permitted" under the default
   profile, OK under `seccomp=unconfined`; `danger-full-access`
   always worked because it skips sandbox construction entirely).
   Fix: `security_opt: [seccomp=unconfined]` on the six
   codex-capable compose files (`hermes_codex`, `hermes_all`, both
   codex dashboards, `dev`, `sandbox` — deliberately NOT
   `docs`/`review`, which are offline by design).
2. **The "bundled bubblewrap" is a lie in these images.** Codex
   0.147.0's startup warning promises a bundled bwrap fallback; at
   shell-launch time it panics instead
   (`linux-sandbox/src/launcher.rs`: "no system bwrap was found on
   PATH and no bundled codex-resources/bwrap binary was found next
   to the Codex executable" — RUST_LOG=debug trace, MSI-PC). The
   laptop passed after fix 1 alone because its 6.6 kernel carries
   codex's `apply_patch`/Landlock write leg; MSI-PC's 5.15 kernel
   (Landlock ABI v1) does not, so it needed the shell leg working —
   i.e. real bwrap. Fix: system `bubblewrap` baked into all three
   codex-capable Dockerfiles (`agent`, `hermes_codex`, `hermes_all`).

Also fixed while in there: **codex is version-pinned everywhere**
(`ARG CODEX_VERSION=rust-v0.147.0` for the musl binaries,
`@openai/codex@0.147.0` for npm) — `releases/latest` floated, so two
images built hours apart could silently diverge; during this
investigation identical-version-across-images was luck, not
guarantee. Bump deliberately, retest the workspace-write delegation,
then update the tag.

**Acceptance, host-verified ** the exact
originally-failing delegation
(`codex exec --skip-git-repo-check --sandbox workspace-write`,
workdir=/vault/agent_inbox) writes successfully on BOTH machines,
through BOTH ephemeral `hermes_all` AND `dashboard_all`, on a fresh
workspace — plus Claude and Hermes's own `write_file` into the new
inbox subfolders. Full matrix green. MSI-PC closed WITHOUT the
kernel update (bwrap alone carried it); `wsl --update` off 5.15
remains optional hygiene there, no longer load-bearing.

Guards added: 11 health_check checks, 8 bats tests (suite 130→138),
root-cause comments in `hermes_codex.yaml` and the Dockerfiles.

### Resolved: agent_inbox output subfolders

`reports/`, `research/`, `sessions/` inside `agent_inbox` — report
organization WITHOUT a second writable root (single-funnel design
deliberately kept; extending `HERMES_WRITE_SAFE_ROOT` was considered
and declined). Writable by every tool automatically because
permissions live on the MOUNT, not per-folder. Embedded in setup.sh
(mkdir phase + .gitkeeps tracked by the inbox's nested repo + health
checks + bats), so DR drills recreate them. Codex rule: keep
`workdir=/vault/agent_inbox` (the `.git` root, for the trust check)
and put the subfolder in the relative filename — `reports/foo.md`.

---

## 2. local_models.md — append to the Codex investigation section

### The ending: seccomp + missing bwrap

The full causal chain, for the record: workspace-write = bubblewrap
= unprivileged user namespaces = blocked by the docker daemon's
default seccomp profile (both machines' daemons — the probe that
proved it: `docker run --rm <hermes image> bash -c "unshare -U true"`
fails under the default profile, succeeds with
`--security-opt seccomp=unconfined`). On top of that, the 0.147.0
musl binary has NO working bundled bwrap despite its startup warning
claiming otherwise — it panics at shell launch (launcher.rs, caught
via `RUST_LOG=debug`). The laptop masked leg 2 because kernel 6.6's
Landlock lets codex's `apply_patch` fallback write without any
shell; MSI-PC's 5.15 could not. Fixes: compose-level
`seccomp=unconfined` + system bubblewrap in the images + version
pin. Both machines confirmed end-to-end.

### Verification hazards — now four flavors

1. Local model **fabricates** a delegation result (recalled prior
   content presented as fresh execution — the original case).
2. Local model reports failure honestly but **misdiagnoses** it
   (narration drift: "missing its required bwrap runtime" wording
   that implied a different codex build than reality).
3. **`codex exec` exits 0 on task failure.** A failed write still
   returns success to the shell — Hermes then truthfully relays a
   false success from a lying exit code. Never trust codex's exit
   status for task outcomes.
4. **Hermes silently substitutes its own `write_file`** for a
   failed CLI delegation, leaving real files on disk that falsely
   "prove" the CLI worked (observed: joke-file session, MSI-PC).
   Attribution must be checked, not just file existence.

Rule unchanged, now with teeth: the only verdict is a host-side
`ls`/`cat` of the target file — and knowing WHICH tool wrote it.

### The raw-capture diagnostic pattern

When a delegation fails and the narration can't be trusted, capture
codex's own output via bash redirection (a write by BASH, not by
codex, so it lands even when codex's sandboxed writes fail):

```
Use your terminal tool with workdir=/vault/agent_inbox and pty=true to run: bash -c "codex exec --skip-git-repo-check --sandbox workspace-write '<task>' > codex_raw.log 2>&1; echo EXIT_CODE=$? >> codex_raw.log"
```

Add `-e RUST_LOG=debug` (via `docker exec`) for the sandbox
backend's own errors — that's what surfaced the launcher panic.
For direct `docker exec` CLI tests, remember credentials live at
the hermes user's home: `-u 1000 -e HOME=/opt/data/home`, or the
CLI runs credential-less and 401s.

### security_opt is container-CREATION-time

Ephemeral profiles (`run --rm`) pick up compose changes on every
launch. `up -d` dashboards keep their birth-time image AND settings
until a real recreate — `run.sh down` + relaunch; a `restart` is
NOT enough. Verify with:
`docker inspect <name> --format '{{.HostConfig.SecurityOpt}}'`.

---

## 3. delegation_phrasing.md — two additions

Under the write-recipes section:

> **Subfolder writes (reports/, research/, sessions/):** keep
> `workdir=/vault/agent_inbox` — the `.git` root that satisfies
> Codex's trust check — and put the subfolder in the RELATIVE
> filename: `"write the report to reports/foo.md"`. Setting
> `workdir=` to the subfolder itself re-breaks the trust check
> (no `.git` down there). Claude and `write_file` accept the same
> relative-path form; one convention covers all three tools.

Under the verification section:

> **`codex exec` exits 0 even when the task failed.** Hermes
> relaying "executed successfully" can be a truthful report of a
> lying exit code. The only verdict is the file itself, host-side —
> and if the file exists, confirm which tool wrote it (Hermes has
> been observed silently substituting its own `write_file` for a
> failed CLI delegation).
