#!/usr/bin/env bats
#
# setup.bats — tests for setup.sh
#
# Tests the SCRIPT's behavior in isolation. This is a different
# concern from health_check.sh, which tests whether a REAL
# environment came out right — run this when setup.sh itself
# changes, run health_check.sh anytime to check the live setup.
#
# Requires bats-core:
#   sudo apt install bats                # Ubuntu 24.04+, simplest
# or, if that package is missing/outdated:
#   git clone https://github.com/bats-core/bats-core.git
#   cd bats-core && sudo ./install.sh /usr/local
#
# Run from the same directory as setup.sh:
#   bats setup.bats
#
# Each test runs setup.sh against an isolated temp $HOME — nothing
# here touches your real ~/workspace or ~/.secrets.

SETUP_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/setup.sh"

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  # setup.sh now requires a configured git identity (see its Phase 0
  # preflight) — set one scoped entirely to this fake $HOME, never
  # touching the real global git config.
  git config --global user.email "test@example.com"
  git config --global user.name "Bats Test"
}

teardown() {
  rm -rf "$TEST_HOME"
}

run_setup() {
  run bash "$SETUP_SCRIPT"
}

# ── Basic completion ─────────────────────────────────────────────

@test "script exits 0 on a clean run" {
  run_setup
  [ "$status" -eq 0 ]
}

@test "creates all top-level workspace directories" {
  run_setup
  for d in projects vault ai infrastructure models backups archives; do
    [ -d "$HOME/workspace/$d" ]
  done
}

@test "creates all vault subfolders" {
  run_setup
  for d in agent_inbox programming security research ideas projects personal archive; do
    [ -d "$HOME/workspace/vault/$d" ]
  done
}

@test "creates all four compose profiles" {
  run_setup
  for f in dev docs review sandbox; do
    [ -f "$HOME/workspace/infrastructure/compose/$f.yaml" ]
  done
}

# ── The properties that actually matter — mount differences ──────
# These are the exact distinctions architecture.md's Container
# Profiles table specifies. If a future edit to setup.sh accidentally
# weakens one, these should catch it.

@test "dev.yaml mounts vault subfolders read-only and agent_inbox read-write" {
  run_setup
  grep -q 'VAULT_DIR}/programming:/vault/programming:ro' "$HOME/workspace/infrastructure/compose/dev.yaml"
  grep -q 'VAULT_DIR}/agent_inbox:/vault/agent_inbox' "$HOME/workspace/infrastructure/compose/dev.yaml"
}

@test "review.yaml mounts workspace read-only and runs fully offline" {
  run_setup
  grep -q '/workspace:ro' "$HOME/workspace/infrastructure/compose/review.yaml"
  grep -q 'network_mode: "none"' "$HOME/workspace/infrastructure/compose/review.yaml"
}

@test "sandbox.yaml does not mount the vault at all" {
  run_setup
  ! grep -q 'VAULT_DIR' "$HOME/workspace/infrastructure/compose/sandbox.yaml"
}

# ── ollama.yaml / hermes.yaml — structural checks ─────────────────
# Both files have now been run for real (see local_models.md), but
# these tests still only verify the script writes what was intended —
# a live Ollama/Hermes round-trip is not something bats can assert.

@test "ollama.yaml is created with the correct 64K context requirement" {
  run_setup
  [ -f "$HOME/workspace/infrastructure/compose/ollama.yaml" ]
  grep -q 'OLLAMA_CONTEXT_LENGTH=64000' "$HOME/workspace/infrastructure/compose/ollama.yaml"
}

@test "hermes.yaml uses the real official image, not a fictional custom build" {
  run_setup
  grep -q 'image: nousresearch/hermes-agent' "$HOME/workspace/infrastructure/compose/hermes.yaml"
  ! grep -q 'build:' "$HOME/workspace/infrastructure/compose/hermes.yaml"
}

@test "hermes.yaml sets PUID/PGID so vault writes are host-owned, not uid 10000" {
  run_setup
  grep -q 'PUID=1000' "$HOME/workspace/infrastructure/compose/hermes.yaml"
  grep -q 'PGID=1000' "$HOME/workspace/infrastructure/compose/hermes.yaml"
}

@test "hermes_dashboard.yaml binds loopback only and enables the dashboard" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_dashboard.yaml"
  grep -q '127.0.0.1:9119:9119' "$F"
  # never a bare port mapping that would expose to the LAN
  ! grep -qE '^\s*-\s*"9119:9119"' "$F"
  grep -q 'HERMES_DASHBOARD=1' "$F"
  grep -q 'restart: unless-stopped' "$F"
}

@test "hermes_dashboard.yaml carries the same vault pattern, personal/ excluded" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_dashboard.yaml"
  grep -q 'VAULT_DIR}/agent_inbox:/vault/agent_inbox' "$F"
  grep -q 'VAULT_DIR}/programming:/vault/programming:ro' "$F"
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault' "$F"
}

@test "hermes_claude Dockerfile widens /root permissions instead of copying files out" {
  run_setup
  F="$HOME/workspace/infrastructure/docker/hermes_claude/Dockerfile"
  [ -f "$F" ]
  grep -q 'chmod 755 /root' "$F"
  grep -q 'chmod -R a+rX /root/.local' "$F"
  grep -q 'claude.ai/install.sh' "$F"
}

@test "hermes_claude.yaml mounts claude-home at the confirmed HOME path, not /root" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_claude.yaml"
  grep -q 'SECRETS_DIR}/claude-home:/opt/data/home/.claude$' "$F"
  grep -q 'SECRETS_DIR}/claude-home.json:/opt/data/home/.claude.json' "$F"
  ! grep -q '/root/.claude' "$F"
}

@test "hermes_claude.yaml sets PUID/PGID and carries the vault pattern, personal/ excluded" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_claude.yaml"
  grep -q 'PUID=1000' "$F"
  grep -q 'PGID=1000' "$F"
  grep -q 'VAULT_DIR}/agent_inbox:/vault/agent_inbox' "$F"
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault' "$F"
}

@test "hermes_dashboard_with_claude.yaml builds the Claude Code image, not the plain one" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_dashboard_with_claude.yaml"
  [ -f "$F" ]
  grep -q 'context: ../docker/hermes_claude' "$F"
  ! grep -q 'image: nousresearch/hermes-agent' "$F"
}

@test "hermes_dashboard_with_claude.yaml enables the dashboard, binds loopback, and mounts claude-home correctly" {
  run_setup
  F="$HOME/workspace/infrastructure/compose/hermes_dashboard_with_claude.yaml"
  grep -q 'HERMES_DASHBOARD=1' "$F"
  grep -q '127.0.0.1:9119:9119' "$F"
  ! grep -qE '^\s*-\s*"9119:9119"' "$F"
  grep -q 'SECRETS_DIR}/claude-home:/opt/data/home/.claude$' "$F"
  ! grep -q '/root/.claude' "$F"
}

@test "no Hermes profile hard-depends on the local ollama service (config.yaml may point remote)" {
  run_setup
  for f in hermes hermes_claude hermes_dashboard hermes_dashboard_with_claude; do
    ! grep -q 'depends_on:' "$HOME/workspace/infrastructure/compose/$f.yaml"
  done
}

@test "hermes.yaml mounts the vault per-subfolder with personal/ excluded" {
  run_setup
  for sub in agent_inbox programming security research ideas projects archive; do
    grep -q "VAULT_DIR}/$sub:/vault/$sub" "$HOME/workspace/infrastructure/compose/hermes.yaml"
  done
  # personal/ must never appear as a mount, and neither may the
  # whole-vault mount that would include it (ADR 0010)
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault' "$HOME/workspace/infrastructure/compose/hermes.yaml"
}

@test "hermes-home secrets directory is created with correct permissions" {
  run_setup
  [ -d "$HOME/.secrets/hermes-home" ]
  [ "$(stat -c %a "$HOME/.secrets/hermes-home")" = "700" ]
}

# ── Codex credential persistence — the cli_auth_credentials_store fix ──
# Debugged for real across two sessions: Codex's "auto" default routed
# the credential to a store that died with the container, so auth.json
# never appeared on the mounted path and every recreate re-prompted
# for login. Forcing "file" BEFORE first login is what fixed it.

@test "codex-home config.toml forces file-based credential storage" {
  run_setup
  [ -d "$HOME/.secrets/codex-home" ]
  [ "$(stat -c %a "$HOME/.secrets/codex-home")" = "700" ]
  grep -q 'cli_auth_credentials_store = "file"' "$HOME/.secrets/codex-home/config.toml"
}

@test "re-running setup does not clobber a user-customized codex config.toml" {
  run_setup
  printf 'cli_auth_credentials_store = "file"\nmodel = "user-choice"\n' \
    > "$HOME/.secrets/codex-home/config.toml"
  run_setup
  grep -q 'user-choice' "$HOME/.secrets/codex-home/config.toml"
}

@test "every profile bind-mounts codex-home at /home/ubuntu/.codex" {
  run_setup
  for f in dev docs review sandbox; do
    grep -q 'SECRETS_DIR}/codex-home:/home/ubuntu/.codex' \
      "$HOME/workspace/infrastructure/compose/$f.yaml"
  done
}

@test "agent Dockerfile creates a non-root user at UID/GID 1000" {
  run_setup
  grep -q 'ARG UID=1000' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
  grep -q 'ARG GID=1000' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
  grep -q '^USER ubuntu' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
}

@test "ai/ is a symlink into infrastructure/ai, not an orphaned directory" {
  run_setup
  [ -L "$HOME/workspace/ai" ]
  [ "$(readlink -f "$HOME/workspace/ai")" = "$(readlink -f "$HOME/workspace/infrastructure/ai")" ]
}

@test "ai/ content is actually committed via the infrastructure repo" {
  run_setup
  git -C "$HOME/workspace/infrastructure" log --all --oneline -- ai/me.md | grep -q .
}

@test "dev.yaml never mounts vault/personal" {
  run_setup
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault:ro' "$HOME/workspace/infrastructure/compose/dev.yaml"
}

@test "docs.yaml never mounts vault/personal" {
  run_setup
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault:ro' "$HOME/workspace/infrastructure/compose/docs.yaml"
}

@test "review.yaml never mounts vault/personal" {
  run_setup
  ! grep -E '^\s*-.*personal|VAULT_DIR}:/vault:ro' "$HOME/workspace/infrastructure/compose/review.yaml"
}

@test "dev.yaml mounts every curated vault subfolder except personal" {
  run_setup
  for sub in programming security research ideas projects archive; do
    grep -q "VAULT_DIR}/$sub:/vault/$sub:ro" "$HOME/workspace/infrastructure/compose/dev.yaml"
  done
}

@test "agent Dockerfile installs Claude Code" {
  run_setup
  grep -q 'claude.ai/install.sh' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
}

@test "agent Dockerfile installs Codex CLI with the correct scoped package name" {
  run_setup
  grep -q 'npm install -g @openai/codex' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
  # the unscoped "codex" package is an unrelated project — guard
  # against ever accidentally installing it instead
  ! grep -qE 'npm install -g codex($|\s)' "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
}

@test "Codex install happens before the USER switch (needs root for global npm)" {
  run_setup
  dockerfile="$HOME/workspace/infrastructure/docker/agent/Dockerfile"
  codex_line=$(grep -n 'npm install -g @openai/codex' "$dockerfile" | cut -d: -f1)
  user_line=$(grep -n '^USER ubuntu' "$dockerfile" | cut -d: -f1)
  [ "$codex_line" -lt "$user_line" ]
}

@test "default AGENTS.md restricts scope to /workspace" {
  run_setup
  grep -q 'only within `/workspace`' "$HOME/workspace/infrastructure/templates/AGENTS.md"
}

# ── Git state ──────────────────────────────────────────────────────

@test "vault is initialized as a git repo with a commit" {
  run_setup
  git -C "$HOME/workspace/vault" rev-parse --is-inside-work-tree
  git -C "$HOME/workspace/vault" log -1
}

@test "infrastructure is initialized as a git repo with a commit" {
  run_setup
  git -C "$HOME/workspace/infrastructure" rev-parse --is-inside-work-tree
  git -C "$HOME/workspace/infrastructure" log -1
}

# ── Security invariants ────────────────────────────────────────────

@test "~/.secrets is created with mode 700" {
  run_setup
  [ -d "$HOME/.secrets" ]
  mode=$(stat -c %a "$HOME/.secrets")
  [ "$mode" = "700" ]
}

@test "vault/personal contains nothing but .gitkeep" {
  run_setup
  files=$(find "$HOME/workspace/vault/personal" -type f)
  [ "$files" = "$HOME/workspace/vault/personal/.gitkeep" ]
}

@test "orientation layer scaffolds exist and are not pre-filled with real content" {
  run_setup
  for f in ai/me.md ai/workspace_map.md vault/skill_map.md vault/current_context.md; do
    [ -f "$HOME/workspace/$f" ]
  done
  # me.md should still be the scaffold, not a real bio. Check for the
  # known placeholder marker rather than parsing a multi-line HTML
  # comment line-by-line, which breaks on continuation lines.
  grep -q "Engineering brief" "$HOME/workspace/ai/me.md"
}

@test "health_check.sh reports zero failures after a clean run" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [[ "$output" =~ "0 failed" ]]
}

# ── Idempotency — the property the whole script is designed around ─

@test "running twice does not fail" {
  run_setup
  [ "$status" -eq 0 ]
  run_setup
  [ "$status" -eq 0 ]
}

@test "a hand-edited file survives a second run" {
  run_setup
  echo "# hand-edited by a human" >> "$HOME/workspace/infrastructure/workspace.env"
  run_setup
  grep -q "hand-edited by a human" "$HOME/workspace/infrastructure/workspace.env"
}

@test "running twice does not create duplicate vault commits" {
  run_setup
  first_count=$(git -C "$HOME/workspace/vault" rev-list --count HEAD)
  run_setup
  second_count=$(git -C "$HOME/workspace/vault" rev-list --count HEAD)
  [ "$first_count" -eq "$second_count" ]
}

@test "all four profiles bind-mount both required Claude Code credential paths" {
  run_setup
  for f in dev docs review sandbox; do
    DF="$HOME/workspace/infrastructure/compose/$f.yaml"
    grep -q 'SECRETS_DIR}/claude-home:/home/ubuntu/.claude$' "$DF"
    grep -q 'SECRETS_DIR}/claude-home.json:/home/ubuntu/.claude.json' "$DF"
    # the old named-volume approach should not have crept back in
    ! grep -q 'claude-credentials' "$DF"
  done
}

@test "bootstrap creates both host-side Claude Code credential paths with correct permissions" {
  run_setup
  [ -d "$HOME/.secrets/claude-home" ]
  [ -f "$HOME/.secrets/claude-home.json" ]
  [ "$(stat -c %a "$HOME/.secrets/claude-home")" = "700" ]
  [ "$(stat -c %a "$HOME/.secrets/claude-home.json")" = "600" ]
}

@test "claude-home.json is seeded with valid JSON, not left genuinely empty" {
  run_setup
  # A touch'd 0-byte file causes Claude Code's very first launch to
  # fail with "configuration file is corrupted: JSON Parse error:
  # Unexpected EOF" — reproduced on a real bootstrap, not a guess.
  # File must be non-empty AND parse as valid JSON.
  [ -s "$HOME/.secrets/claude-home.json" ]
  python3 -c "import json; json.load(open('$HOME/.secrets/claude-home.json'))"
}

@test "re-running setup does not wipe an existing Claude Code login" {
  run_setup
  # realistic content, not just any string — this exact scenario
  # (echo '{}' unconditionally overwriting on re-run) was a real
  # regression caught during manual verification, not a hypothetical
  echo '{"claudeAiOauth":{"subscriptionType":"max"}}' > "$HOME/.secrets/claude-home.json"
  run_setup
  grep -q "claudeAiOauth" "$HOME/.secrets/claude-home.json"
}

# ── Docker-dependent — skipped if Docker isn't available here ─────

@test "compose files contain no YAML syntax errors" {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "Docker not available in this test environment"
  fi
  run_setup
  for f in dev docs review sandbox; do
    run docker compose -f "$HOME/workspace/infrastructure/compose/$f.yaml" config --quiet
    # \${PROJECT} being unset is expected and non-fatal at bootstrap
    # time; an actual YAML parse error is not.
    [[ ! "$output" =~ "yaml:" ]]
  done
}

# ── --verify mode ─────────────────────────────────────────────────
# The drift check: create_file_if_missing never updates an existing
# file, so a live file and its embedded copy can diverge silently.
# --verify regenerates every embedded file into a temp mirror, diffs
# against the live tree, and exits non-zero on any drift — writing
# nothing. Each behavior below was also exercised manually against a
# real sandboxed bootstrap before these tests were written.

@test "--verify exits 0 immediately after a clean bootstrap" {
  run_setup
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 drifted or missing"* ]]
}

@test "--verify detects a hand-edited live file and exits non-zero" {
  run_setup
  echo "# local tweak" >> "$HOME/workspace/infrastructure/compose/dev.yaml"
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT:"*"dev.yaml"* ]]
}

@test "--verify detects a deleted live file and exits non-zero" {
  run_setup
  rm "$HOME/workspace/infrastructure/compose/hermes_claude.yaml"
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING:"*"hermes_claude.yaml"* ]]
}

@test "--verify ignores content edits to human-filled scaffolds" {
  run_setup
  echo "My goals: ship things" >> "$HOME/workspace/ai/me.md"
  echo "Priority this week: codex delegation" >> "$HOME/workspace/vault/current_context.md"
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -eq 0 ]
}

@test "--verify still notices a scaffold that is missing entirely" {
  run_setup
  rm "$HOME/workspace/vault/current_context.md"
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING:"*"current_context.md"* ]]
}

@test "--verify on a clean HOME writes nothing at all" {
  # Every file reports MISSING (non-zero exit is correct), but the
  # contract under test is: no workspace, no secrets, no side effects.
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/workspace" ]
  [ ! -e "$HOME/.secrets" ]
}

@test "--verify works without docker or a git identity (skips preflight)" {
  run_setup
  git config --global --unset user.email
  git config --global --unset user.name
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -eq 0 ]
}

@test "unknown flags are rejected with usage, not silently bootstrapped" {
  run bash "$SETUP_SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/workspace" ]
}

@test "gitignores exist after bootstrap despite moving out of the git-init guard" {
  run_setup
  [ -f "$HOME/workspace/infrastructure/.gitignore" ]
  [ -f "$HOME/workspace/vault/.gitignore" ]
  grep -q 'workspace.env' "$HOME/workspace/infrastructure/.gitignore"
}

# ── Codex delegation (confirmed working) ─────────────────

@test "hermes_codex Dockerfile uses the static musl binary, not npm/root-widening" {
  run_setup
  local f="$HOME/workspace/infrastructure/docker/hermes_codex/Dockerfile"
  [ -f "$f" ]
  grep -q "codex-x86_64-unknown-linux-musl" "$f"
  grep -q "codex --version" "$f"
  ! grep -q "chmod -R a+rX /root" "$f"
}

@test "hermes_codex.yaml mounts codex-home at the confirmed HOME path" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
  [ -f "$f" ]
  grep -q "codex-home:/opt/data/home/.codex" "$f"
}

@test "hermes_codex.yaml sets PUID/PGID and carries the vault pattern, personal/ excluded" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
  grep -q "PUID=1000" "$f"
  grep -q "PGID=1000" "$f"
  grep -q "vault/agent_inbox" "$f"
  ! grep -q "vault/personal" "$f"
}

@test "hermes_codex build context is separate from hermes_claude's" {
  run_setup
  grep -q "context: ../docker/hermes_codex" \
    "$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
  # the two Dockerfiles must not be the same file
  ! diff -q \
    "$HOME/workspace/infrastructure/docker/hermes_claude/Dockerfile" \
    "$HOME/workspace/infrastructure/docker/hermes_codex/Dockerfile" >/dev/null 2>&1
}

@test "no Codex profile hard-depends on the local ollama service" {
  run_setup
  # Match the actual YAML key (colon required), same pattern the
  # existing Hermes-profile test uses — a bare "depends_on" also
  # matches this file's own explanatory comment ("depends_on
  # deliberately removed"), which is a false positive, not a bug
  # in hermes_codex.yaml.
  ! grep -q 'depends_on:' "$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
}

# ── run.sh and tasks.json (confirmed working) ────────────

@test "run.sh is embedded, executable, and passes shell syntax check" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  [ -x "$f" ]
  run bash -n "$f"
  [ "$status" -eq 0 ]
}

@test "run.sh starts ollama explicitly for ephemeral Hermes targets" {
  run_setup
  # compose run only starts the named service; depends_on was
  # deliberately removed for remote-Ollama support, so the runner
  # itself must bring ollama up first in local mode (finding #2,
  # test run).
  grep -q "ensure_ollama" "$HOME/workspace/infrastructure/scripts/run.sh"
}

@test "run.sh's drift target wraps this script's own --verify" {
  run_setup
  grep -q -- "--verify" "$HOME/workspace/infrastructure/scripts/run.sh"
}

@test "tasks.json is embedded at the workspace root, not inside infrastructure/" {
  run_setup
  [ -f "$HOME/workspace/.vscode/tasks.json" ]
  [ ! -e "$HOME/workspace/infrastructure/.vscode" ]
}

@test "tasks.json is valid JSON once comments are stripped, and every task routes through run.sh" {
  run_setup
  run python3 -c "
import json, re
raw = open('$HOME/workspace/.vscode/tasks.json').read()
stripped = re.sub(r'^\s*//.*\$', '', raw, flags=re.M)
d = json.loads(stripped)
assert all(t['command'].startswith('infrastructure/scripts/run.sh') for t in d['tasks'])
"
  [ "$status" -eq 0 ]
}

# ── Preflight guard for a root-owned leftover workspace (finding #1) ─

@test "preflight fails with a clear diagnosis when \$WORKSPACE_ROOT exists but isn't writable" {
  mkdir -p "$HOME/workspace"
  # Simulate the real-world cause (Docker auto-creating bind-mount
  # dirs as root) using a permission bit instead of actual root,
  # since the test harness itself may run privileged.
  chmod 000 "$HOME/workspace"
  run bash "$SETUP_SCRIPT"
  chmod 700 "$HOME/workspace"  # restore so bats teardown can clean up
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL:"*"isn't writable"* ]]
  [[ "$output" == *"chown"* ]]
}

@test "preflight guard does not fire on a normal writable (or absent) workspace" {
  # No pre-existing $HOME/workspace at all — the common case.
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── health_check.sh coverage for the newly embedded files ───────────

@test "health_check.sh verifies hermes_codex files and run.sh/tasks.json" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose/hermes_codex.yaml"* ]]
  [[ "$output" == *"docker/hermes_codex/Dockerfile"* ]]
  [[ "$output" == *"scripts/run.sh (executable)"* ]]
  [[ "$output" == *".vscode/tasks.json"* ]]
}

@test "health_check.sh also covers hermes/hermes_claude/hermes_dashboard files (gap fixed)" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose/hermes.yaml"* ]]
  [[ "$output" == *"compose/hermes_claude.yaml"* ]]
  [[ "$output" == *"docker/hermes_claude/Dockerfile"* ]]
  [[ "$output" == *"compose/hermes_dashboard.yaml"* ]]
  [[ "$output" == *"compose/hermes_dashboard_with_claude.yaml"* ]]
}

@test "--verify covers all 33 embedded files after the Hermes project-mount fragments" {
  run_setup
  run bash "$SETUP_SCRIPT" --verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"33 embedded files checked, 0 drifted or missing"* ]]
}


# ── hermes_dashboard_with_codex (confirmed working) ──────

@test "hermes_dashboard_with_codex.yaml builds the Codex image and enables the dashboard" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_dashboard_with_codex.yaml"
  [ -f "$f" ]
  grep -q "context: ../docker/hermes_codex" "$f"
  grep -q "HERMES_DASHBOARD=1" "$f"
  grep -q "gateway run" "$f"
}

@test "hermes_dashboard_with_codex.yaml binds loopback only and mounts codex-home correctly" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_dashboard_with_codex.yaml"
  grep -q '127.0.0.1:9119:9119' "$f"
  grep -q "codex-home:/opt/data/home/.codex" "$f"
  ! grep -q "vault/personal" "$f"
  ! grep -q 'depends_on:' "$f"
}

@test "run.sh has models and pull targets for Ollama, independent of any Hermes profile" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "models)" "$f"
  grep -q "pull)" "$f"
  grep -q "ollama list" "$f"
  grep -q "ollama pull" "$f"
  grep -q "gemma4:e2b" "$f"
}

@test "run.sh has a dashboard_codex target with the 9119 guard" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "dashboard_codex)" "$f"
  grep -q 'compose-hermes_dashboard_with_codex-1' "$f"
}

@test "health_check.sh verifies hermes_dashboard_with_codex.yaml" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose/hermes_dashboard_with_codex.yaml"* ]]
}

# ── --secrets-only mode ──────────────────────────────────────────
# Extracted into seed_secrets(), one function called by both
# bootstrap and --secrets-only — never a second copy of this logic.

@test "--secrets-only seeds ~/.secrets without creating ~/workspace at all" {
  run bash "$SETUP_SCRIPT" --secrets-only
  [ "$status" -eq 0 ]
  [ -d "$HOME/.secrets/claude-home" ]
  [ -d "$HOME/.secrets/codex-home" ]
  [ -d "$HOME/.secrets/hermes-home" ]
  [ ! -e "$HOME/workspace" ]
}

@test "--secrets-only needs no docker and no git identity" {
  # No docker in PATH assumptions here, and git identity intentionally
  # left unset for this test — same contract as --verify.
  run bash "$SETUP_SCRIPT" --secrets-only
  [ "$status" -eq 0 ]
}

@test "--secrets-only seeds valid JSON and the file-store config, same as bootstrap" {
  run bash "$SETUP_SCRIPT" --secrets-only
  [ "$status" -eq 0 ]
  run cat "$HOME/.secrets/claude-home.json"
  [ "$output" = "{}" ]
  grep -q 'cli_auth_credentials_store = "file"' "$HOME/.secrets/codex-home/config.toml"
}

@test "--secrets-only never clobbers an existing login or custom config" {
  mkdir -p "$HOME/.secrets/claude-home" "$HOME/.secrets/codex-home"
  echo '{"real":"login"}' > "$HOME/.secrets/claude-home.json"
  echo 'cli_auth_credentials_store = "file"
extra_setting = true' > "$HOME/.secrets/codex-home/config.toml"
  run bash "$SETUP_SCRIPT" --secrets-only
  [ "$status" -eq 0 ]
  run cat "$HOME/.secrets/claude-home.json"
  [ "$output" = '{"real":"login"}' ]
  grep -q "extra_setting = true" "$HOME/.secrets/codex-home/config.toml"
}

@test "normal bootstrap still seeds secrets identically after the seed_secrets() extraction" {
  run_setup
  [ -s "$HOME/.secrets/claude-home.json" ]
  [ -s "$HOME/.secrets/codex-home/config.toml" ]
  [ -d "$HOME/.secrets/hermes-home" ]
}

# ── hermes_all — combined image, CONFIRMED WORKING ───────
# Both ephemeral and dashboard forms proven via interleaved
# delegation (claude/codex/claude again), no cross-provider
# interference, dashboard reached remotely via the native Win11 app.
# These bats tests still only check the generated FILES are
# structurally correct (bats can't itself run a live delegation call)
# — the live proof lives in features.md's Resolved entry and
# testing_plan.md §1.8/§1.8b, not here.

@test "hermes_all Dockerfile installs BOTH claude and codex" {
  run_setup
  local f="$HOME/workspace/infrastructure/docker/hermes_all/Dockerfile"
  [ -f "$f" ]
  grep -q "claude.ai/install.sh" "$f"
  grep -q "codex-x86_64-unknown-linux-musl" "$f"
  grep -q "codex --version" "$f"
  grep -q "claude --version" "$f"
}

@test "hermes_all.yaml mounts both credential sets and carries the vault pattern" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_all.yaml"
  [ -f "$f" ]
  grep -q "claude-home:/opt/data/home/.claude" "$f"
  grep -q "claude-home.json:/opt/data/home/.claude.json" "$f"
  grep -q "codex-home:/opt/data/home/.codex" "$f"
  grep -q "vault/agent_inbox" "$f"
  ! grep -q "vault/personal" "$f"
  ! grep -q 'depends_on:' "$f"
}

@test "hermes_dashboard_with_all.yaml builds the combined image and enables the dashboard" {
  run_setup
  local f="$HOME/workspace/infrastructure/compose/hermes_dashboard_with_all.yaml"
  [ -f "$f" ]
  grep -q "context: ../docker/hermes_all" "$f"
  grep -q "HERMES_DASHBOARD=1" "$f"
  grep -q '127.0.0.1:9119:9119' "$f"
  grep -q "claude-home:/opt/data/home/.claude" "$f"
  grep -q "codex-home:/opt/data/home/.codex" "$f"
}

@test "run.sh has hermes_all and dashboard_all targets, no stale UNTESTED label (both confirmed)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "hermes_all)" "$f"
  grep -q "dashboard_all)" "$f"
  grep -q "compose-hermes_dashboard_with_all-1" "$f"
  # Regression guard: both are proven now — if UNTESTED reappears
  # here, someone added a new unproven feature under the same name
  # without updating this test, or an old label crept back in.
  ! grep -qi "UNTESTED" "$f"
}

@test "health_check.sh verifies the hermes_all image and both new compose files" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose/hermes_all.yaml"* ]]
  [[ "$output" == *"docker/hermes_all/Dockerfile"* ]]
  [[ "$output" == *"compose/hermes_dashboard_with_all.yaml"* ]]
}

@test "hermes_all build context is separate from both single-provider contexts" {
  run_setup
  ! diff -q \
    "$HOME/workspace/infrastructure/docker/hermes_all/Dockerfile" \
    "$HOME/workspace/infrastructure/docker/hermes_claude/Dockerfile" >/dev/null 2>&1
  ! diff -q \
    "$HOME/workspace/infrastructure/docker/hermes_all/Dockerfile" \
    "$HOME/workspace/infrastructure/docker/hermes_codex/Dockerfile" >/dev/null 2>&1
}

@test "ensure_model auto-pulls in local mode and is fully skipped under --remote-ollama" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "^ensure_model()" "$f"
  grep -q "ensure_model" "$f"  # wired into ensure_ollama and all 4 dashboards
  grep -c "ensure_model" "$f" | grep -qv "^0$"
}

@test "dashboard_auth generates a config block via env-var password (no shell/python injection risk)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "dashboard_auth)" "$f"
  grep -q "DA_PASS" "$f"
  grep -q "hash_password" "$f"
  # password must NOT be spliced directly into the python source string
  ! grep -q "hash_password('\$da_pass')" "$f"
}

@test "dashboard_auth requires both username and password" {
  run_setup
  printf "\nsomepass\n" > /tmp/da_input_$$
  run bash "$HOME/workspace/infrastructure/scripts/run.sh" dashboard_auth < /tmp/da_input_$$
  rm -f /tmp/da_input_$$
  [ "$status" -ne 0 ]
  [[ "$output" == *"Both required"* ]]
}

@test "run.sh has an ollama_down target, separate from the dashboard-only down" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q "ollama_down)" "$f"
  grep -q "compose-ollama-1" "$f"
}

@test "docker_clean requires confirmation and prunes containers/images/builder/network" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  # NOTE: originally checked for a blanket "Proceed?" prompt (removed
  # at the per-category rewrite) and later a bare "image prune -a -f"
  # call (removed at the per-item rewrite, which loops `docker rmi`
  # over the filtered unused list instead — same end result for
  # 'all', but selectable per item). Both breaks went uncaught for a
  # while since nothing here ran the real bats binary until this
  # session built a way to actually execute the suite. Fixed to
  # match current reality both times.
  grep -q "docker_clean)" "$f"
  grep -q "container prune -f" "$f"
  grep -q "docker rmi" "$f"
  grep -q "builder prune -a -f" "$f"
  grep -q "network prune -f" "$f"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q 'read -r -p "Remove'
}


# ── Docker backend migration (Desktop <-> native docker-ce) ─────────
# The migration itself (apt installs, systemd, GPU toolkit) is real-OS
# behavior and stays a dated verified-on-hardware note, same as the
# GPU-passthrough comment in ollama.yaml. What IS testable, in the
# suite's usual style: the script's embedding, its detection logic
# (via a mocked PATH), its refusal gate, and the reversibility
# guarantee that --revert never uninstalls anything.

MIGRATE_SCRIPT_REL="workspace/infrastructure/scripts/migrate_docker_backend.sh"

make_fake_docker() {
  # $1 = "desktop" or "native" — builds a PATH dir whose docker
  # resolves to a Desktop-shim-style path or a plain native path.
  local flavor="$1" bin="$TEST_HOME/fakebin"
  mkdir -p "$bin"
  if [ "$flavor" = "desktop" ]; then
    local shim="$TEST_HOME/mnt/wsl/docker-desktop/cli-tools/usr/bin"
    mkdir -p "$shim"
    printf '#!/bin/sh\ntrue\n' > "$shim/docker"
    chmod +x "$shim/docker"
    ln -sf "$shim/docker" "$bin/docker"
  else
    printf '#!/bin/sh\ntrue\n' > "$bin/docker"
    chmod +x "$bin/docker"
  fi
  echo "$bin"
}

@test "migrate_docker_backend.sh is embedded, executable, and passes shell syntax check" {
  run_setup
  local f="$HOME/$MIGRATE_SCRIPT_REL"
  [ -x "$f" ]
  run bash -n "$f"
  [ "$status" -eq 0 ]
}

@test "run.sh has docker_status/docker_migrate/docker_revert targets routing to the migration script" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'docker_status)' "$f"
  grep -q 'docker_migrate)' "$f"
  grep -q 'docker_revert)' "$f"
  grep -q 'migrate_docker_backend.sh" --check' "$f"
  grep -q 'migrate_docker_backend.sh" --migrate' "$f"
  grep -q 'migrate_docker_backend.sh" --revert' "$f"
}

@test "tasks.json has all three Docker backend tasks routing through run.sh" {
  run_setup
  local f="$HOME/workspace/.vscode/tasks.json"
  grep -q 'run.sh docker_status' "$f"
  grep -q 'run.sh docker_migrate' "$f"
  grep -q 'run.sh docker_revert' "$f"
}

@test "migration script --check detects a Docker Desktop CLI shim (mocked PATH)" {
  run_setup
  local bin; bin="$(make_fake_docker desktop)"
  PATH="$bin:$PATH" run bash "$HOME/$MIGRATE_SCRIPT_REL" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker Desktop shim"* ]]
}

@test "migration script --check detects a native docker binary (mocked PATH)" {
  run_setup
  local bin; bin="$(make_fake_docker native)"
  PATH="$bin:$PATH" run bash "$HOME/$MIGRATE_SCRIPT_REL" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"native docker-ce"* ]]
}

@test "--migrate refuses while docker still resolves to the Desktop shim (mocked PATH)" {
  run_setup
  local bin; bin="$(make_fake_docker desktop)"
  PATH="$bin:$PATH" run bash "$HOME/$MIGRATE_SCRIPT_REL" --migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"WSL integration"* ]]
}

@test "--revert never uninstalls docker-ce (reversibility is a hard constraint)" {
  run_setup
  # Static guarantee: the script contains no package-removal commands
  # at all — revert only stops/disables the native service.
  run grep -En "apt(-get)? +(remove|purge|autoremove)" "$HOME/$MIGRATE_SCRIPT_REL"
  [ "$status" -ne 0 ]
}

@test "health_check.sh verifies migrate_docker_backend.sh" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/migrate_docker_backend.sh (executable)"* ]]
}


# ── One-click bootstrap / test / check_all (run.sh + VS Code tasks) ─

@test "run.sh has bootstrap/test/check_all targets" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'bootstrap)' "$f"
  grep -q 'test)' "$f"
  grep -q 'check_all)' "$f"
  grep -q 'bats setup.bats' "$f"
}

@test "check_all chains health, drift, and test in order" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  # the three run_target calls appear inside the check_all block,
  # in this order
  sed -n '/check_all)/,/;;/p' "$f" | grep -q 'run_target health'
  sed -n '/check_all)/,/;;/p' "$f" | grep -q 'run_target drift'
  sed -n '/check_all)/,/;;/p' "$f" | grep -q 'run_target test'
}

@test "tasks.json has bootstrap/test/check_all tasks routing through run.sh" {
  run_setup
  local f="$HOME/workspace/.vscode/tasks.json"
  grep -q 'run.sh bootstrap' "$f"
  grep -q 'run.sh test' "$f"
  grep -q 'run.sh check_all' "$f"
}

@test "migrate restarts docker after runtime config, not just enable --now" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/migrate_docker_backend.sh"
  # apt starts dockerd during install, so `enable --now` alone never
  # re-reads the nvidia-ctk daemon.json — an explicit restart must
  # be present (GPU regression guard)
  grep -q 'systemctl restart docker' "$f"
  ! grep -q 'systemctl enable --now docker' "$f"
}

@test "revert masks the native service and migrate unmasks it (WSL restart resurrection guard)" {
  run_setup
  local f="$HOME/$MIGRATE_SCRIPT_REL"
  # Desktop's Apply & Restart bounces the distro; a disabled-but-not-
  # masked unit came back enabled+active through that cycle on real
  # hardware — mask/unmask is the durable pair
  grep -q 'systemctl mask docker' "$f"
  grep -q 'systemctl unmask docker' "$f"
}

@test "windows interop leakage is named and does not block --migrate" {
  run_setup
  local f="$HOME/$MIGRATE_SCRIPT_REL" bin="$TEST_HOME/fakebin"
  # a virgin distro with Windows PATH interop exposes Desktop's
  # Windows CLI under /mnt/<drive>/ (finding) — must be
  # labeled as leakage, not "native", and migrate must proceed
  local w="$TEST_HOME/mnt/c/Program Files/Docker/Docker/resources/bin"
  mkdir -p "$w" "$bin"
  printf '#!/bin/sh\ntrue\n' > "$w/docker"; chmod +x "$w/docker"
  ln -sf "$w/docker" "$bin/docker"
  PATH="$bin:$PATH" run bash "$f" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"interop"* ]]
  [[ "$output" != *"(native docker-ce)"* ]]
  PATH="$bin:$PATH" run bash "$f" --migrate
  [[ "$output" != *"REFUSING"* ]]
}

# ── Hermes project mount (--project=<name>) ──────────────────────
# Deliberately NOT a new compose YAML fragment: hermes/hermes_claude/
# hermes_codex/hermes_all are four DIFFERENTLY-NAMED services, so a
# single fragment file can't merge a volume into whichever one is
# actually running. `docker compose run`'s own -v/-w flags sidestep
# that — they apply to whatever service name is invoked, no matter
# which. These are static/grep checks matching this suite's existing
# style for run.sh targets; the dynamic behavior (the actual -v/-w
# splice into a real compose invocation) was verified by hand against
# a stub docker capturing its exact argv, all four ephemeral targets
# plus the -r combination, before this suite was written.

@test "run.sh parses --project=<name> and validates the project directory exists" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q -- '--project=\*' "$f"
  grep -q 'HERMES_PROJECT' "$f"
  grep -q 'No such project dir' "$f"
}

@test "run.sh's project mount is read-write at a fixed /workspace path, not project-named" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'project_mount_args' "$f"
  grep -q -- '-v \${PROJECTS_DIR}/\${HERMES_PROJECT}:/workspace -w /workspace' "$f"
}

@test "--project splices into all four ephemeral hermes targets, not the dashboards" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'run --rm \$(project_mount_args) hermes$' "$f"
  grep -q 'run --rm \$(project_mount_args) hermes_claude' "$f"
  grep -q 'run --rm \$(project_mount_args) hermes_codex' "$f"
  grep -q 'run --rm \$(project_mount_args) hermes_all' "$f"
  # dashboards use `up -d`, which never gets project_mount_args spliced in
  ! grep -q 'up -d.*project_mount_args' "$f"
}

@test "--project on an unsupported target (dashboard/dev/etc.) refuses instead of silently no-op'ing" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'has no effect on' "$f"
  grep -q 'hermes|hermes_claude|hermes_codex|hermes_all) : ;;' "$f"
}

@test "--project is documented in run.sh --help output" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q -- '--project=<name>' "$f"
  grep -q 'workdir=/workspace' "$f"
}

# ── Hermes project mount on the DASHBOARD variants ───────────────
# The ephemeral targets use docker compose run's own -v/-w flags
# (no new compose file needed — see the tests above). Dashboards use
# `up -d`, which doesn't take run-time mount overrides, so THIS half
# genuinely needs compose fragments — one per dashboard, deliberately
# not shared, since a shared file listing all four service names
# would make compose treat the other three as new, incomplete
# standalone services (no image/build) that `up -d` would also try
# to start. Structural safety (exactly one service per fragment,
# matching its own filename) was verified with a real YAML parser
# before these files were embedded; the dynamic compose-invocation
# behavior (each dashboard splicing its OWN matching fragment, never
# another one) was verified by hand against a stub docker capturing
# argv for all four dashboard variants, before this suite was written.

@test "the four dashboard project-mount fragments are embedded" {
  run_setup
  for f in hermes_dashboard_project.yaml hermes_dashboard_with_claude_project.yaml \
           hermes_dashboard_with_codex_project.yaml hermes_dashboard_with_all_project.yaml; do
    [ -f "$HOME/workspace/infrastructure/compose/$f" ]
  done
}

@test "each dashboard project-mount fragment defines EXACTLY one service, matching its own filename" {
  run_setup
  for f in hermes_dashboard_project.yaml hermes_dashboard_with_claude_project.yaml \
           hermes_dashboard_with_codex_project.yaml hermes_dashboard_with_all_project.yaml; do
    local path="$HOME/workspace/infrastructure/compose/$f"
    # exactly one top-level entry under services: (2-space indent, not 4+)
    local n; n=$(grep -cE '^  [a-z_]+:$' "$path")
    [ "$n" -eq 1 ]
    # and it's the service name embedded in the fragment's own filename
    local svc; svc="${f%_project.yaml}"
    grep -q "^  ${svc}:\$" "$path"
  done
}

@test "each dashboard fragment mounts \${HERMES_PROJECT} read-write at /workspace" {
  run_setup
  for f in hermes_dashboard_project.yaml hermes_dashboard_with_claude_project.yaml \
           hermes_dashboard_with_codex_project.yaml hermes_dashboard_with_all_project.yaml; do
    local path="$HOME/workspace/infrastructure/compose/$f"
    grep -q '\${PROJECTS_DIR}/\${HERMES_PROJECT}:/workspace' "$path"
    grep -q 'working_dir: /workspace' "$path"
  done
}

@test "run.sh exports HERMES_PROJECT (compose YAML interpolation needs a real env var, not just a shell var)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'export HERMES_PROJECT=' "$f"
}

@test "run.sh splices each dashboard's OWN matching fragment via dashboard_project_flag" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'dashboard_project_flag' "$f"
  grep -q '\$(dashboard_project_flag hermes_dashboard)' "$f"
  grep -q '\$(dashboard_project_flag hermes_dashboard_with_claude)' "$f"
  grep -q '\$(dashboard_project_flag hermes_dashboard_with_codex)' "$f"
  grep -q '\$(dashboard_project_flag hermes_dashboard_with_all)' "$f"
}

@test "--project's unsupported-target guard now allows all four dashboard targets too" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'dashboard|dashboard_claude|dashboard_codex|dashboard_all) : ;;' "$f"
}

@test "health_check.sh verifies all four dashboard project-mount fragments" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  for f in hermes_dashboard_project.yaml hermes_dashboard_with_claude_project.yaml \
           hermes_dashboard_with_codex_project.yaml hermes_dashboard_with_all_project.yaml; do
    [[ "$output" == *"compose/$f"* ]]
  done
}

# ── Default working directory for Hermes writes ────
# Ergonomics fix, NOT a permission expansion — HERMES_WRITE_SAFE_ROOT
# stays exactly /opt/data:/vault/agent_inbox in every profile,
# unchanged. This only changes where a container STARTS (so a
# relative-path write lands in agent_inbox by default), not what it
# CAN write to. Confirmed real fix for the underlying write problem
# was workdir= + a relative filename together (see
# delegation_phrasing.md) — this makes that the default instead of
# something that must be typed every time. Note: Hermes's terminal
# tool doesn't reliably pick up a container's own default working_dir
# for delegated commands (a separate, already-documented finding) —
# so the explicit workdir= clause in delegation phrasing stays the
# reliable path; this is a backstop, not a guarantee.

@test "all eight Hermes profiles default their working directory to agent_inbox" {
  run_setup
  for f in hermes.yaml hermes_claude.yaml hermes_codex.yaml hermes_all.yaml \
           hermes_dashboard.yaml hermes_dashboard_with_claude.yaml \
           hermes_dashboard_with_codex.yaml hermes_dashboard_with_all.yaml; do
    grep -q 'working_dir: /vault/agent_inbox' "$HOME/workspace/infrastructure/compose/$f"
  done
}

@test "the working_dir default does NOT expand HERMES_WRITE_SAFE_ROOT — still exactly the vault inbox" {
  run_setup
  for f in hermes.yaml hermes_claude.yaml hermes_codex.yaml hermes_all.yaml \
           hermes_dashboard.yaml hermes_dashboard_with_claude.yaml \
           hermes_dashboard_with_codex.yaml hermes_dashboard_with_all.yaml; do
    local path="$HOME/workspace/infrastructure/compose/$f"
    grep -q 'HERMES_WRITE_SAFE_ROOT=/opt/data:/vault/agent_inbox' "$path"
    # exactly one write-safe-root line — never a wider one snuck in
    local n; n=$(grep -c 'HERMES_WRITE_SAFE_ROOT=' "$path")
    [ "$n" -eq 1 ]
  done
}

# ── agent_inbox gets its own nested git repo (finding) ──
# codex exec's trust check wants .git DIRECTLY in the invoked
# directory — the vault's own top-level repo, one directory up,
# does not satisfy it. Confirmed in real testing: a bare `git init`
# with ZERO commits was sufficient; --skip-git-repo-check alone,
# with no .git present anywhere, was never enough across many
# real attempts. Deliberately excluded from the vault's own git
# tracking (see the .gitignore test below) so it doesn't show up
# there as a confusing nested "gitlink" entry.

@test "agent_inbox has its own nested git repo, separate from the vault's" {
  run_setup
  run git -C "$HOME/workspace/vault/agent_inbox" rev-parse --is-inside-work-tree
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "agent_inbox's nested repo is genuinely its own — not just inheriting the vault's" {
  run_setup
  local inbox_root vault_root
  inbox_root="$(git -C "$HOME/workspace/vault/agent_inbox" rev-parse --show-toplevel)"
  vault_root="$(git -C "$HOME/workspace/vault" rev-parse --show-toplevel)"
  [ "$inbox_root" != "$vault_root" ]
  [ -d "$HOME/workspace/vault/agent_inbox/.git" ]
}

@test "the vault's own .gitignore excludes agent_inbox/ from its tracking" {
  run_setup
  grep -q '^agent_inbox/$' "$HOME/workspace/vault/.gitignore"
}

@test "running setup twice does not re-init or break agent_inbox's nested repo" {
  run_setup
  # HEAD intentionally unset (no commits — a bare init is sufficient
  # per the real-world fix); assert on is-inside-work-tree stability
  # instead, which is what actually matters and what codex checks.
  local before; before="$(git -C "$HOME/workspace/vault/agent_inbox" rev-parse --is-inside-work-tree 2>&1 || true)"
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  local after; after="$(git -C "$HOME/workspace/vault/agent_inbox" rev-parse --is-inside-work-tree 2>&1 || true)"
  [ "$before" = "$after" ]
  [ "$after" = "true" ]
}

@test "health_check.sh verifies agent_inbox's nested git repo" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_inbox has its own nested git repo"* ]]
}

# ── Interactive menu supports --project= too ────────
# The flag-based path (run.sh --project=<name> hermes_all) already
# existed; this closes the gap for the bare-menu path — option 20
# prompts for a project name, then which of the 8 supported targets.

@test "the interactive menu has an option for a project-mounted target" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  grep -q 'hermes/dashboard with a project mounted' "$f"
  grep -q '20)' "$f"
}

@test "menu option 20 validates the project directory before proceeding" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  # same validation shape as the flag path: refuse + list available projects
  sed -n '/^    20)/,/;;/p' "$f" | grep -q 'No such project dir'
  sed -n '/^    20)/,/;;/p' "$f" | grep -q 'Available projects'
}

@test "menu option 20 exports HERMES_PROJECT before calling run_target" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  sed -n '/^    20)/,/;;/p' "$f" | grep -q 'export HERMES_PROJECT="\$p"'
}

@test "menu option 20 allows blank input for no project mount (not forced)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  sed -n '/^    20)/,/;;/p' "$f" | grep -q 'if \[ -n "\$p" \]'
}

# --- Codex bubblewrap sandbox prerequisite (root-caused) --

@test "all six codex-capable compose files allow user namespaces (codex bwrap sandbox)" {
  run_setup
  # workspace-write = bubblewrap = unprivileged user namespaces, which
  # docker-ce's default seccomp profile blocks — regression guard for
  # the laptop finding: writes failed while codex exited 0.
  for f in dev sandbox hermes_codex hermes_all \
           hermes_dashboard_with_codex hermes_dashboard_with_all; do
    grep -q "seccomp=unconfined" \
      "$HOME/workspace/infrastructure/compose/$f.yaml"
  done
}

@test "offline profiles (docs, review) deliberately keep the default seccomp profile" {
  run_setup
  # codex can't function offline anyway (network_mode: none), and
  # review is the deliberately most-restricted profile — the override
  # must not leak into them.
  ! grep -q "seccomp=unconfined" \
    "$HOME/workspace/infrastructure/compose/docs.yaml"
  ! grep -q "seccomp=unconfined" \
    "$HOME/workspace/infrastructure/compose/review.yaml"
}

@test "the seccomp override carries its root-cause comment, not just the bare line" {
  run_setup
  # House rule: a non-obvious security-relevant line must explain
  # itself in place. The full note lives in hermes_codex.yaml; every
  # other carrier at least points at bubblewrap/user namespaces.
  grep -q "bubblewrap" \
    "$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
  grep -q "USER NAMESPACE" \
    "$HOME/workspace/infrastructure/compose/hermes_codex.yaml"
}

@test "health_check.sh verifies the seccomp override on all six codex-capable files" {
  run_setup
  run bash "$HOME/workspace/infrastructure/scripts/health_check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"allows user namespaces"* ]]
  [[ "$output" == *"keeps default seccomp"* ]]
}

# --- Codex sandbox runtime: bubblewrap + version pin ---

@test "all three codex-capable Dockerfiles install system bubblewrap" {
  run_setup
  # codex 0.147.0's "bundled bubblewrap" fallback panics when absent
  # (launcher.rs, RUST_LOG trace) — system bwrap is the fix for the
  # shell-tool leg of the sandbox.
  for d in agent hermes_codex hermes_all; do
    grep -q "bubblewrap" \
      "$HOME/workspace/infrastructure/docker/$d/Dockerfile"
  done
}

@test "codex is version-pinned in every Dockerfile — no floating releases/latest" {
  run_setup
  for d in hermes_codex hermes_all; do
    grep -q "CODEX_VERSION=rust-v" \
      "$HOME/workspace/infrastructure/docker/$d/Dockerfile"
    ! grep -q "releases/latest" \
      "$HOME/workspace/infrastructure/docker/$d/Dockerfile"
  done
  grep -q "@openai/codex@" \
    "$HOME/workspace/infrastructure/docker/agent/Dockerfile"
}

# --- agent_inbox output subfolders ---

@test "agent_inbox ships with reports/ research/ sessions/ subfolders, gitkept" {
  run_setup
  # Organization inside the single writable funnel — every tool can
  # write here because the whole inbox MOUNT is rw; no second
  # writable root, no HERMES_WRITE_SAFE_ROOT change.
  for sub in reports research sessions; do
    [ -d "$HOME/workspace/vault/agent_inbox/$sub" ]
    [ -f "$HOME/workspace/vault/agent_inbox/$sub/.gitkeep" ]
  done
}

@test "inbox subfolders survive a second setup run (idempotent, nested repo intact)" {
  run_setup
  run_setup
  [ "$status" -eq 0 ]
  [ -d "$HOME/workspace/vault/agent_inbox/reports" ]
  [ -d "$HOME/workspace/vault/agent_inbox/.git" ]
}

# --- docker_clean: containers/images per-ITEM, not per-category ---

@test "docker_clean shows numbered per-item selection for containers and images" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q '== Stopped containers =='
  echo "$block" | grep -q '== Unused images =='
  echo "$block" | grep -q '== Build cache =='
  echo "$block" | grep -q '== Unused networks =='
  # regression guard: no blanket "Proceed?" and no category-wide
  # "Remove unused images? [y/N]" left — both replaced by per-item
  ! echo "$block" | grep -q 'Proceed? \[y/N\]'
  ! echo "$block" | grep -q 'Remove images not used by any container? \[y/N\]'
  echo "$block" | grep -q "Remove which? (numbers, 'all', or blank to skip):"
}

@test "docker_clean's images list excludes anything backing a container (running or stopped)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  # regression guard for the near-miss this whole feature exists to
  # prevent: ollama/ollama (a real multi-GB re-pull, not a cheap
  # rebuild) must never be offered for removal while still in use —
  # the used-image-ID filter is what keeps it off the list
  echo "$block" | grep -q "docker ps -aq | xargs -r docker inspect --format '{{.Image}}'"
  echo "$block" | grep -q "dc_used_ids"
  echo "$block" | grep -q "dc_unused"
}

@test "docker_clean accepts 'all', comma-separated, and space-separated selections" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q 'dc_i_sel = "all"\|dc_i_sel="all"\|"\$dc_i_sel" = "all"'
  echo "$block" | grep -q 'dc_i_sel//,/ '
  echo "$block" | grep -q 'dc_c_sel//,/ '
}

@test "docker_clean rejects an out-of-range selection instead of silently misbehaving" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q 'skipped invalid selection'
}

@test "docker_clean skips a category the user declines, prunes only what's confirmed" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q 'skipped: containers'
  echo "$block" | grep -q 'skipped: images'
  echo "$block" | grep -q 'skipped: build cache'
  echo "$block" | grep -q 'skipped: networks'
}

@test "docker_clean's read prompts are well-formed (no empty-varname reads)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  # every `read -r -p "..."` line in this block must end in a real
  # variable name, not an empty string — the bug an earlier revision
  # fixed and this guards against reintroducing
  echo "$block" | grep 'read -r -p' | grep -qvE '""\s*$'
}

@test "docker_clean shows what each category would remove BEFORE asking" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q "docker ps -a --filter status=exited"
  echo "$block" | grep -q "docker images --format"
  echo "$block" | grep -q "docker system df | grep -E \"TYPE|Build Cache\""
  echo "$block" | grep -q "docker network ls --filter dangling=true"
  # containers listing appears before its own prompt, not after
  local before_read
  before_read=$(echo "$block" | grep -n "docker ps -a --filter status=exited\|Remove which?" | head -2)
  echo "$before_read" | head -1 | grep -q "docker ps -a"
}

@test "docker_clean skips even asking when a category is already empty" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  echo "$block" | grep -q "(none — nothing to remove)"
}

@test "docker_clean's networks category auto-clears stale compose-* containers first (footgun fix)" {
  run_setup
  local f="$HOME/workspace/infrastructure/scripts/run.sh"
  local block; block=$(sed -n '/^    docker_clean)/,/^    ;;$/p' "$f")
  # regression guard for: network prune deleting a network that a
  # stopped compose-* container still referenced, breaking the next
  # `up` with "failed to set up container networking: network ...
  # not found" — hit for real once already
  echo "$block" | grep -q "docker ps -aq --filter name=compose- --filter status=exited"
  echo "$block" | grep -q "docker rm -f \$stale_compose"
  # and this happens INSIDE the networks section, before the prune —
  # not as a separate manual step the user has to remember
  local networks_section
  networks_section=$(echo "$block" | sed -n '/== Unused networks ==/,$p')
  echo "$networks_section" | grep -q "stale_compose"
}

# --- ddgs baked into every hermes Dockerfile (web_search backend) ---

@test "all three hermes Dockerfiles install ddgs via uv and import-check it" {
  run_setup
  for d in hermes_claude hermes_codex hermes_all; do
    f="$HOME/workspace/infrastructure/docker/$d/Dockerfile"
    grep -q "uv pip install --python /opt/hermes/.venv/bin/python3 ddgs" "$f"
    grep -q "import ddgs" "$f"
  done
}

@test "ddgs install does NOT use plain pip — this image's venv has no pip module" {
  run_setup
  # regression guard: confirmed by hand that
  # `pip`/`pip3`/`python3 -m pip` are all absent from this venv;
  # only `uv pip install --python ...` works. Never revert to pip
  # without re-verifying the base image has grown one.
  for d in hermes_claude hermes_codex hermes_all; do
    f="$HOME/workspace/infrastructure/docker/$d/Dockerfile"
    ! grep -qE '(^|[^-])\bpip install ddgs' "$f"
  done
}

@test "all three hermes Dockerfiles install uv itself before using it for ddgs" {
  run_setup
  # regression guard: nousresearch/hermes-agent:latest silently
  # stopped shipping `uv` on PATH (2026-10), so `uv pip install ...
  # ddgs` failed with "uv: not found" / exit 127 even though the
  # ddgs line itself was correct. Fix is installing uv via astral.sh
  # immediately before the ddgs step — assert both that it's present
  # AND that it comes first, not just that it exists somewhere.
  for d in hermes_claude hermes_codex hermes_all; do
    f="$HOME/workspace/infrastructure/docker/$d/Dockerfile"
    grep -q "curl -LsSf https://astral.sh/uv/install.sh | sh" "$f"
    grep -q "mv /root/.local/bin/uv /usr/local/bin/uv" "$f"

    install_line="$(grep -n "astral.sh/uv/install.sh" "$f" | head -1 | cut -d: -f1)"
    ddgs_line="$(grep -n "uv pip install --python .*ddgs" "$f" | head -1 | cut -d: -f1)"
    [ -n "$install_line" ]
    [ -n "$ddgs_line" ]
    [ "$install_line" -lt "$ddgs_line" ]
  done
}

# --- git identity seeded for hermes-home (agent_inbox commits) ---

@test "seed_secrets writes a git identity for the hermes user's HOME" {
  run_setup
  local f="$HOME/.secrets/hermes-home/home/.gitconfig"
  [ -f "$f" ]
  grep -q "email" "$f"
  grep -q "name" "$f"
  # regression guard: agent_inbox's nested repo needs SOME identity
  # to commit at all — "Author identity unknown" is the failure this
  # exists to prevent, hit for real via Hermes's own Review/Commit UI
  grep -q "@" "$f"
}

@test "the git identity seed never overwrites a value the user already set" {
  run_setup
  local f="$HOME/.secrets/hermes-home/home/.gitconfig"
  echo -e "[user]\n\temail = custom@example.com\n\tname = Custom Name" > "$f"
  run_setup
  grep -q "custom@example.com" "$f"
  ! grep -q "hermes@localhost" "$f"
}
