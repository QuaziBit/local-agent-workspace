# local-agent-workspace

A Docker/WSL2 multi-agent development environment: local and
desktop Ollama models, Claude Code and Codex CLI delegation through
Hermes (chat and dashboard forms), and a direct-use tier for
hands-on dev/docs/review/sandbox work — all sharing one Obsidian
vault with enforced mount boundaries.

Personal project, proven on real hardware across two machines:
sandbox isolation, web search, per-tier mount boundaries, and both
Hermes delegation mechanisms are all host-verified, not just
documented. See `notes/features.md` for what's actually proven vs.
still open.

---

## Support

If this project saved you time or helped you, you can support it here:

☕ https://buymeacoffee.com/QuaziBit

---

## Quick start

Make a folder, drop the scripts in it, and run init:

```bash
mkdir -p ~/workspace && cd ~/workspace    # any folder name works
# copy init.sh, setup.sh, setup.bats, init.bats, migrate_docker_backend.sh here
bash init.sh
```

One script, run first on any machine. Detects what's missing,
offers the next step, resumes where it left off. It asks once where
the workspace should live (Enter = `~/workspace`; or pass
`--dir <path>` to skip the question), builds everything there, and
copies the scripts into `<workspace>/init/`. See `notes/setup.md`
for the full walkthrough.

## What's in here

- **`notes/`** — start with `notes/readme.md`, the doc map. Routes
  by what you're trying to do rather than by file name.
- **`scripts/`** — `setup.sh` (bootstrap), `run.sh` (day-to-day
  runner), `init.sh` (first run on a new machine), `smoke_test.sh`
  (one-command check that the sandbox and search stack actually
  work on a live container).

## Status

Personal learning project, not a production system. Local git only
by choice — CI, scanning, and production-hardening are consciously
deferred in favor of "easy to set up and usable right away."

## License

MIT — see `LICENSE`.
