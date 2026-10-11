#!/usr/bin/env bash
#
# smoke_test.sh — run this after ANY change to the hermes images,
# compose files, or config.yaml. Not a replacement for
# health_check.sh (which checks the WORKSPACE TREE is bootstrapped
# correctly) — this checks that a LIVE container's sandbox and
# search actually work right now, the way health_check.sh checks
# structure and this checks behavior.
#
# What it exercises, all things this project has been burned by
# once: bubblewrap presence, the daemon seccomp override, real user
# namespace creation, ddgs importability, and (the only verdict that
# actually counts) a real codex + claude write landing on disk,
# checked host-side — never by trusting what either CLI or Hermes
# says happened.
#
# Usage:
#   bash smoke_test.sh                    # auto-detects a running
#                                          # hermes/dashboard container
#   bash smoke_test.sh <container-name>   # or name one explicitly
#
# Run from anywhere — it only touches <workspace root>/vault/agent_inbox
# (root: INIT_WORKSPACE_ROOT if set; else derived from this script's
# own location when it sits in <root>/infrastructure/scripts/; else
# ~/workspace).

set -uo pipefail   # not -e: run every check, report all of them

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${INIT_WORKSPACE_ROOT:-}" ]; then
  WS_ROOT="$INIT_WORKSPACE_ROOT"
elif [ "$(basename "$_here")" = "scripts" ] \
  && [ "$(basename "$(dirname "$_here")")" = "infrastructure" ]; then
  WS_ROOT="$(dirname "$(dirname "$_here")")"
else
  WS_ROOT="$HOME/workspace"
fi
INBOX="$WS_ROOT/vault/agent_inbox"
PASS=0
FAIL=0

check() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/tmp/smoke_test_out 2>&1; then
    echo "  OK    $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    sed 's/^/        /' /tmp/smoke_test_out | head -5
    FAIL=$((FAIL + 1))
  fi
}

# ── Pick a container ─────────────────────────────────────────────

CONTAINER="${1:-}"
if [ -z "$CONTAINER" ]; then
  CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 'compose-hermes_dashboard_with_all')
fi
if [ -z "$CONTAINER" ]; then
  CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 'compose-hermes_all-run')
fi
if [ -z "$CONTAINER" ]; then
  echo "No running hermes/dashboard container found."
  echo "Start one first (run.sh dashboard_all or run.sh hermes_all),"
  echo "or pass a container name: bash smoke_test.sh <name>"
  exit 1
fi
echo "== Testing container: $CONTAINER =="
echo

# ── Sandbox prerequisites (the seccomp/bwrap saga, in five lines) ──

echo "== Sandbox prerequisites =="
check "bubblewrap present" \
  "docker exec '$CONTAINER' bash -c 'command -v bwrap'"
check "codex is pinned to 0.147.0, not floating" \
  "docker exec '$CONTAINER' codex --version | grep -q 0.147.0"
check "seccomp override is live on this container" \
  "docker inspect '$CONTAINER' --format '{{.HostConfig.SecurityOpt}}' | grep -q seccomp=unconfined"
check "unprivileged user namespaces work (as the hermes user, uid 1000)" \
  "docker exec -u 1000 '$CONTAINER' bash -c 'unshare -U true'"
check "ddgs is importable (web_search backend)" \
  "docker exec '$CONTAINER' /opt/hermes/.venv/bin/python3 -c 'import ddgs'"
echo

# ── Real writes — the only verdict that counts ──────────────────

echo "== Real writes (verified host-side, not by trusting CLI output) =="
mkdir -p "$INBOX/reports"

CODEX_MARK="SMOKE_CODEX_$$"
docker exec -u 1000 -e HOME=/opt/data/home -w /vault/agent_inbox "$CONTAINER" \
  codex exec --skip-git-repo-check --sandbox workspace-write \
  "write the text $CODEX_MARK to reports/smoke_codex.txt" >/dev/null 2>&1
check "codex workspace-write actually landed a file" \
  "grep -q '$CODEX_MARK' '$INBOX/reports/smoke_codex.txt'"

CLAUDE_MARK="SMOKE_CLAUDE_$$"
docker exec -u 1000 -e HOME=/opt/data/home -w /vault/agent_inbox "$CONTAINER" \
  claude -p --permission-mode acceptEdits \
  "write the text $CLAUDE_MARK to reports/smoke_claude.txt" >/dev/null 2>&1
check "claude write actually landed a file" \
  "grep -q '$CLAUDE_MARK' '$INBOX/reports/smoke_claude.txt'"

echo
echo "== Summary: $PASS passed, $FAIL failed =="
rm -f "$INBOX/reports/smoke_codex.txt" "$INBOX/reports/smoke_claude.txt" /tmp/smoke_test_out

[ "$FAIL" -eq 0 ]
