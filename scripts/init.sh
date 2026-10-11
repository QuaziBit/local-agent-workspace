#!/usr/bin/env bash
#
# init.sh — the single master entry point for this stack.
#
# Run this FIRST on any machine, from the repo/staging folder it lives
# in (alongside setup.sh, setup.bats, migrate_docker_backend.sh).
# It is a STATE DETECTOR, not a questionnaire: it checks reality in
# dependency order and offers the FIRST missing step. Idempotent and
# resumable — quit anytime, re-run, it picks up where things stand.
#
#   bash init.sh            interactive: check everything, offer fixes
#   bash init.sh --check    report-only: change nothing, always exit 0
#
# Born from Run 3: every check below corresponds to a
# real failure hit while standing up a virgin distro on this machine.
# Honest limits (printed, never worked around): the Docker Desktop
# WSL-integration toggle, browser/device-code logins, Portmaster's
# UI, and `wsl --terminate` are outside any script's reach.

set -uo pipefail   # not -e: a detector must report everything it can

# ── Paths (env-overridable so init.bats can point at fixtures) ────
RESOLV_CONF="${INIT_RESOLV_CONF:-/etc/resolv.conf}"
WSL_CONF="${INIT_WSL_CONF:-/etc/wsl.conf}"
SECRETS_DIR="${INIT_SECRETS_DIR:-$HOME/.secrets}"
WORKSPACE_ROOT="${INIT_WORKSPACE_ROOT:-$HOME/workspace}"
APT_SOURCES="${INIT_APT_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$WORKSPACE_ROOT/infrastructure/scripts/run.sh"
PROC_VERSION="${INIT_PROC_VERSION:-/proc/version}"

is_wsl() {
  # WSL2's kernel identifies itself here; real Ubuntu (bare metal,
  # a plain VM, a cloud box) never matches this. Getting this wrong
  # matters: 127.0.0.53 (systemd-resolved) is the NORMAL, healthy
  # default on real Ubuntu — it's only broken under WSL because its
  # upstream is a dead NAT proxy specific to that environment. Without
  # this gate, init would "fix" DNS that was never broken.
  grep -qi microsoft "$PROC_VERSION" 2>/dev/null
}

MODE="${1:---interactive}"
case "$MODE" in
  --check|--interactive) ;;
  -h|--help) echo "Usage: $(basename "$0") [--check]"; exit 0 ;;
  *) echo "Usage: $(basename "$0") [--check]"; exit 1 ;;
esac

# First missing, fixable step found by the scan (name of an action fn)
NEXT_ACTION=""
NEXT_LABEL=""
propose() { [ -n "$NEXT_ACTION" ] || { NEXT_ACTION="$1"; NEXT_LABEL="$2"; }; }

ok()   { echo "  OK    $1"; }
miss() { echo "  MISS  $1"; }
warn() { echo "  WARN  $1"; }
note() { echo "        $1"; }

# ══ Phase 0 — machine environment (the Run 3 gauntlet) ═══════════

check_systemd() {
  if [ -d /run/systemd/system ]; then ok "systemd is running"; else
    miss "systemd not running"
    if is_wsl; then
      propose fix_wsl_conf "write the four-section wsl.conf (systemd, user, interop, network) — needs a wsl --terminate afterward"
    fi
    # off-WSL: no wsl.conf to write; a real Ubuntu install without
    # systemd running is a much deeper problem init won't guess at
  fi

  if ! is_wsl; then
    ok "not WSL — skipping wsl.conf checks (not applicable)"
    return
  fi

  if grep -qs "generateResolvConf[[:space:]]*=[[:space:]]*false" "$WSL_CONF" 2>/dev/null; then
    ok "wsl.conf disables resolv.conf generation"
  else
    miss "wsl.conf missing [network] generateResolvConf=false"
    propose fix_wsl_conf "write the four-section wsl.conf — needs a wsl --terminate afterward"
  fi
  if grep -qs "appendWindowsPath[[:space:]]*=[[:space:]]*false" "$WSL_CONF" 2>/dev/null; then
    ok "wsl.conf strips the Windows interop PATH"
  else
    warn "wsl.conf does not set appendWindowsPath=false — Windows CLIs (incl. Desktop's docker) leak onto PATH"
  fi
}

# The DNS demon's three known forms, plus a live probe.
check_dns() {
  if ! is_wsl; then
    # Real Ubuntu: 127.0.0.53 (systemd-resolved) is the NORMAL,
    # healthy default — flagging it as broken here would be actively
    # wrong, not just unnecessary. Trust the live resolver instead
    # of inspecting resolv.conf's contents at all.
    if timeout 8 getent hosts download.docker.com >/dev/null 2>&1; then
      ok "DNS resolves (download.docker.com)"
    else
      miss "DNS does not resolve download.docker.com"
      note "-> not WSL, so this isn't the known WSL DNS-proxy issue;"
      note "   check this machine's network/resolver configuration directly"
      note "   (init won't guess at the right fix on an unfamiliar network)"
    fi
    return
  fi

  local broken=""
  if [ -L "$RESOLV_CONF" ]; then
    miss "resolv.conf is a symlink (auto-generated — form 1 of the DNS demon)"; broken=1
  elif grep -qs "10\.255\.255\.254" "$RESOLV_CONF" 2>/dev/null; then
    miss "resolv.conf points at WSL's proxy 10.255.255.254 (form 1b)"; broken=1
  elif grep -qs "127\.0\.0\.53" "$RESOLV_CONF" 2>/dev/null; then
    miss "resolv.conf points at systemd-resolved's stub 127.0.0.53 (form 2 — WSL-specific: its upstream is a dead NAT proxy here)"; broken=1
  elif [ -f "$RESOLV_CONF" ]; then
    ok "resolv.conf is a static file ($(grep -m1 '^nameserver' "$RESOLV_CONF" 2>/dev/null || echo 'no nameserver?'))"
    if command -v lsattr >/dev/null 2>&1 && lsattr "$RESOLV_CONF" 2>/dev/null | grep -q '^....i'; then
      ok "resolv.conf is chattr-locked (survives boots)"
    else
      warn "resolv.conf not chattr-locked — systemd-resolved re-symlinks unlocked files on boot"
      propose fix_dns "lock DNS permanently (disable systemd-resolved, static 1.1.1.1/1.0.0.1, chattr +i)"
    fi
  else
    miss "resolv.conf missing entirely"; broken=1
  fi
  [ -z "$broken" ] || propose fix_dns "apply the durable DNS fix (disable systemd-resolved, static file, chattr +i)"
  # Live probe — wrapped in timeout (nothing here is trusted to fail fast)
  if timeout 8 getent hosts download.docker.com >/dev/null 2>&1; then
    ok "DNS resolves (download.docker.com)"
  else
    miss "DNS does not resolve download.docker.com (probe timed out or failed)"
    [ -n "$NEXT_ACTION" ] || propose fix_dns "apply the durable DNS fix"
  fi
}

check_apt_net() {
  # PROBE-based, not "have the mitigation files been applied" — that
  # version unconditionally warned regardless of whether THIS
  # network actually has the problem, the same class of bug as the
  # DNS false-positive, just milder (fix). The root cause
  # (a local firewall throttling plain http — see testing_plan.md)
  # isn't tied to WSL the way the DNS-proxy issue is, so no is_wsl()
  # gate here — just test what apt would actually do right now.
  local scheme="http"
  if [ -f "$APT_SOURCES" ] && ! grep -qs "http://" "$APT_SOURCES"; then
    scheme="https"   # already mitigated — probe what apt would use
  fi
  local t0 t1 ms probe_ok=1
  t0=$(date +%s%N)
  timeout 10 curl -s -o /dev/null --connect-timeout 5 --max-time 8 \
    "${scheme}://archive.ubuntu.com" 2>/dev/null || probe_ok=0
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))

  if [ "$probe_ok" = "1" ] && [ "$ms" -lt 3000 ]; then
    ok "apt mirror ($scheme) responds fine (${ms}ms)"
    return
  fi

  if [ "$probe_ok" = "1" ]; then
    warn "apt mirror ($scheme) is slow (${ms}ms) — a firewall may be throttling it"
  else
    warn "apt mirror ($scheme) connection failed or stalled"
  fi

  if [ "$scheme" = "https" ]; then
    # Already mitigated and still slow — the https+IPv4 fix wouldn't
    # help further; this is a deeper issue outside init's scope.
    note "https + IPv4 pin already applied — this is a different,"
    note "deeper network issue than the known fix addresses"
    return
  fi
  propose fix_apt_net "switch apt to https mirrors + pin IPv4 (fixed this exact symptom before)"
}

check_basics() {
  if git config --global user.name >/dev/null 2>&1 && git config --global user.email >/dev/null 2>&1; then
    ok "git identity set ($(git config --global user.name))"
  else
    miss "git identity not set (setup.sh's commits need it)"
    propose fix_git_identity "set git user.name / user.email"
  fi
  if command -v bats >/dev/null 2>&1; then ok "bats installed"; else
    miss "bats not installed (run.sh test / check_all need it)"
    propose fix_bats "apt install bats"
  fi
}

# ══ Phase 1 — Docker backend ═════════════════════════════════════

docker_flavor() {
  # Same classification the migrate script settled on, findings #4 incl.
  local p
  p="$(command -v docker 2>/dev/null || true)"
  [ -n "$p" ] || { echo "none"; return; }
  p="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  case "$p" in
    */docker-desktop/*|*/mnt/wsl/*) echo "desktop" ;;
    */mnt/[a-z]/*) echo "windows-interop" ;;
    *) echo "native" ;;
  esac
}

check_docker() {
  local flavor; flavor="$(docker_flavor)"
  case "$flavor" in
    native)
      if timeout 10 docker info >/dev/null 2>&1; then
        ok "native docker-ce, daemon reachable, group membership live"
      elif sudo -n true 2>/dev/null && sudo docker info >/dev/null 2>&1; then
        miss "daemon runs but this session lacks the docker group"
        note "-> wsl --terminate this distro from Windows, re-enter, re-run init"
      else
        miss "docker CLI present but daemon not reachable"
        propose fix_docker "run migrate_docker_backend.sh --migrate (starts/repairs the native backend)"
      fi ;;
    windows-interop)
      miss "only Desktop's WINDOWS CLI leaks through interop PATH — no docker in this distro"
      propose fix_docker "install native docker-ce via migrate_docker_backend.sh --migrate" ;;
    desktop)
      miss "docker resolves to the Docker Desktop shim (WSL integration is ON)"
      note "-> turn integration OFF for this distro (Desktop GUI) before installing native docker-ce"
      note "   (or stay on Desktop deliberately — then init's docker phase is done: re-run with the toggle as you want it)" ;;
    none)
      miss "no docker CLI at all"
      propose fix_docker "install native docker-ce via migrate_docker_backend.sh --migrate" ;;
  esac
}

# ══ Phase 2 — workspace ══════════════════════════════════════════

check_workspace() {
  if [ -x "$RUN_SH" ]; then
    ok "workspace bootstrapped ($WORKSPACE_ROOT)"
    # The load-bearing assumption nothing else watches: the staged
    # bootstrap copy vs the workspace's canonical one.
    local ws_setup="$WORKSPACE_ROOT/infrastructure/bootstrap/setup.sh"
    if [ -f "$ws_setup" ] && [ -f "$SCRIPT_DIR/setup.sh" ]; then
      if cmp -s "$ws_setup" "$SCRIPT_DIR/setup.sh"; then
        ok "staged setup.sh matches the workspace's bootstrap copy"
      else
        warn "staged setup.sh DIFFERS from $ws_setup — reconcile ONE direction before trusting either (see setup.sh --verify's rule)"
      fi
    fi
  else
    if [ -f "$SCRIPT_DIR/setup.sh" ]; then
      miss "no bootstrapped workspace yet"
      propose fix_workspace "run setup.sh (creates the whole workspace; needs docker green above)"
    else
      miss "no workspace AND no setup.sh next to init.sh — stage the bootstrap files here first"
    fi
  fi
}

# ══ Phase 3 — credentials (the Run 2 evidence checks) ════════════

check_credentials() {
  local c="$SECRETS_DIR/claude-home/.credentials.json"
  local x="$SECRETS_DIR/codex-home/auth.json"
  if [ -s "$c" ]; then ok "Claude Code credential on disk"; else
    miss "no Claude Code credential"
    propose walk_logins "walk the sandbox login flow (claude + codex)"
  fi
  if [ -s "$x" ]; then ok "Codex credential on disk"; else
    miss "no Codex credential"
    propose walk_logins "walk the sandbox login flow (claude + codex)"
  fi
  if [ -s "$SECRETS_DIR/claude-home/settings.json" ] && grep -qs '"model"' "$SECRETS_DIR/claude-home/settings.json"; then
    ok "Claude default model set ($(grep -o '"model"[^,}]*' "$SECRETS_DIR/claude-home/settings.json" | head -1))"
  else
    warn "no default-model override — Claude Code will use its MOST EXPENSIVE model"
    note "-> echo '{\"model\": \"haiku\"}' > $SECRETS_DIR/claude-home/settings.json (or pick in an interactive claude session)"
  fi
}

# ══ Phase 4 — Hermes ═════════════════════════════════════════════

check_hermes() {
  local cfg="$SECRETS_DIR/hermes-home/config.yaml"
  if grep -qs "custom_providers" "$cfg" 2>/dev/null; then
    ok "Hermes provider configured"
  else
    miss "Hermes has no provider (config.yaml missing/unset — a stale bundled template may lurk in the image)"
    propose walk_hermes "launch run.sh hermes and run 'hermes setup' inside (BEFORE dashboard_auth — setup wipes basic_auth)"
  fi
  if grep -qs "basic_auth" "$cfg" 2>/dev/null; then
    ok "dashboard basic_auth configured"
  else
    miss "no dashboard password"
    # only offer once a provider exists — the ORDER rule, enforced
    if grep -qs "custom_providers" "$cfg" 2>/dev/null; then
      propose walk_dashboard_auth "run run.sh dashboard_auth (safe now: provider already set)"
    else
      note "-> deferred until after 'hermes setup' (order matters: setup wipes basic_auth)"
    fi
  fi
}

# ══ Actions ══════════════════════════════════════════════════════

fix_wsl_conf() {
  local me; me="${USER:-$(id -un)}"
  [ -f "$WSL_CONF" ] && sudo cp "$WSL_CONF" "$WSL_CONF.bak.$(date +%s)"
  sudo tee "$WSL_CONF" >/dev/null << EOF
[boot]
systemd=true
[user]
default=$me
[interop]
appendWindowsPath=false
[network]
generateResolvConf=false
EOF
  echo "wsl.conf written (previous version backed up alongside, if any)."
  echo "NOW, from Windows PowerShell:  wsl --terminate <this-distro>"
  echo "Re-enter the distro and run init.sh again — it resumes from here."
  exit 0
}

fix_dns() {
  if ! is_wsl; then
    echo "REFUSING: this fix disables systemd-resolved permanently,"
    echo "which is the correct, healthy DNS setup on real Ubuntu — it"
    echo "would break a machine that isn't actually broken. This fix"
    echo "is specifically for a known dead WSL2 NAT-DNS proxy."
    echo "Fix DNS through this machine's normal network settings instead."
    return 1
  fi
  # Durable kill for all three forms. Handles an existing chattr lock.
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now systemd-resolved 2>/dev/null || true
  fi
  sudo chattr -i "$RESOLV_CONF" 2>/dev/null || true
  sudo rm -f "$RESOLV_CONF"
  printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' | sudo tee "$RESOLV_CONF" >/dev/null
  sudo chattr +i "$RESOLV_CONF" 2>/dev/null || true
  if timeout 8 getent hosts download.docker.com >/dev/null 2>&1; then
    echo "DNS fixed and locked."
    # Docker's daemon reads the host resolv.conf — restart if present
    command -v systemctl >/dev/null 2>&1 && sudo systemctl restart docker 2>/dev/null || true
  else
    echo "Static resolv.conf written, but the probe still fails — check the"
    echo "firewall layer (Portmaster: the apt/https findings in testing_plan.md)."
  fi
}

fix_apt_net() {
  [ -f "$APT_SOURCES" ] && sudo sed -i 's|http://|https://|g' "$APT_SOURCES"
  echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null
  sudo sed -i 's|^#precedence ::ffff:0:0/96  100|precedence ::ffff:0:0/96  100|' /etc/gai.conf 2>/dev/null || true
  echo "Network profile applied (https mirrors + IPv4 preference)."
}

fix_git_identity() {
  local n e
  read -r -p "git user.name: " n
  read -r -p "git user.email: " e
  git config --global user.name "$n"
  git config --global user.email "$e"
}

fix_bats() { sudo apt-get update && sudo apt-get install -y bats; }

fix_docker() {
  if [ -f "$SCRIPT_DIR/migrate_docker_backend.sh" ]; then
    bash "$SCRIPT_DIR/migrate_docker_backend.sh" --migrate
    echo
    echo "If a docker-group line was printed above:  wsl --terminate <distro>,"
    echo "re-enter, re-run init.sh — it resumes from here."
    exit 0
  else
    echo "migrate_docker_backend.sh not found next to init.sh — stage it here first."
  fi
}

fix_workspace() {
  bash "$SCRIPT_DIR/setup.sh"
  echo

  # Auto-copy, not move: SCRIPT_DIR/setup.sh has to keep
  # existing afterward — the drift-compare a few lines up in this
  # same script (cmp against $ws_setup) and the "no workspace AND no
  # setup.sh next to init.sh" check both depend on it still being
  # here on the NEXT run of init.sh --check. Move would pass today
  # and quietly break both of those the second time around.
  local boot_dir="$WORKSPACE_ROOT/infrastructure/bootstrap"
  local copied=0
  mkdir -p "$boot_dir"
  for f in setup.sh setup.bats; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      cp -f "$SCRIPT_DIR/$f" "$boot_dir/$f"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -gt 0 ]; then
    echo "Copied $copied file(s) into $boot_dir"
    echo "so run.sh drift/test/check_all can find them."
  else
    echo "WARNING: setup.sh/setup.bats not found next to init.sh —"
    echo "nothing copied. Stage them here first, then re-run."
  fi
}

walk_logins() {
  cat << 'EOF'
The login flow cannot be automated (browser + device code), but it is
short — sandbox is the auth home (no prerequisites, and every choice
propagates to all profiles via the shared credential mounts):

  PRE-CHECK: chatgpt.com -> Settings -> Security -> device code auth ON

  run.sh sandbox            # then, inside:
  claude                    #   copy the URL to your Windows browser
  codex login --device-auth #   device code in any browser; set modes
  exit

EOF
  if [ -x "$RUN_SH" ] && [ "$MODE" = "--interactive" ]; then
    local a; read -r -p "Launch run.sh sandbox now? [y/N] " a
    case "$a" in y|Y) bash "$RUN_SH" sandbox ;; esac
  fi
}

walk_hermes() {
  echo "Launching the plain hermes profile — inside it, run:  hermes setup"
  echo "  (Full setup -> Custom endpoint -> http://ollama:11434/v1 ->"
  echo "   Chat Completions -> pick the local model -> name it Ollama-Local)"
  echo "Exit when done and re-run init.sh — dashboard_auth comes next."
  if [ -x "$RUN_SH" ] && [ "$MODE" = "--interactive" ]; then
    local a; read -r -p "Launch run.sh hermes now? [y/N] " a
    case "$a" in y|Y) bash "$RUN_SH" hermes ;; esac
  fi
}

walk_dashboard_auth() { [ -x "$RUN_SH" ] && bash "$RUN_SH" dashboard_auth; }

# ══ Main ═════════════════════════════════════════════════════════

echo "== init: machine environment =="
check_systemd
check_dns
check_apt_net
check_basics
echo "== init: docker backend =="
check_docker
echo "== init: workspace =="
check_workspace
echo "== init: credentials =="
check_credentials
echo "== init: hermes =="
check_hermes
echo

if [ -z "$NEXT_ACTION" ]; then
  echo "All green — this machine is fully set up."
  if [ -x "$RUN_SH" ]; then
    echo "Handing off to the day-to-day runner:  $RUN_SH"
    echo "  (bare run.sh = interactive menu; quick_reference.md = cheat sheet)"
  fi
  exit 0
fi

echo "Next step: $NEXT_LABEL"
if [ "$MODE" = "--check" ]; then
  echo "(--check mode: nothing changed. Run without --check to act.)"
  exit 0
fi
read -r -p "Do it now? [y/N] " ans
case "$ans" in
  y|Y) "$NEXT_ACTION"
       echo
       echo "Re-run init.sh to continue from the next gap." ;;
  *)   echo "Nothing changed. Re-run anytime — init always resumes." ;;
esac
