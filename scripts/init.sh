#!/usr/bin/env bash
#
# init.sh — the single master entry point for this stack.
#
# Run this FIRST on any machine. Put init.sh and the files that ship
# with it (setup.sh, setup.bats, init.bats, migrate_docker_backend.sh)
# together in any folder and run it from there. It asks where the
# workspace should live (default ~/workspace — any name or path works),
# and once the workspace exists it COPIES itself and those files into
# <workspace>/init/ (the originals stay put), so it can be re-run from
# either place.
#
# It is a STATE DETECTOR, not a questionnaire: it checks reality in
# dependency order and offers the FIRST missing step. Idempotent and
# resumable — quit anytime, re-run, it picks up where things stand.
#
#   bash init.sh                interactive: check everything, offer fixes
#   bash init.sh --check        report-only: change nothing, always exit 0
#   bash init.sh --dir <path>   workspace location, skipping the question
#                               (a bare name goes under ~, e.g. --dir ai-lab)
#
# Which workspace folder is used, first match wins:
#   INIT_WORKSPACE_ROOT env > --dir > this script's own location
#   (<root>/init/init.sh) > the choice saved next to this script by an
#   earlier run > an existing ~/workspace install > the question
#   (interactive only; otherwise ~/workspace). One workspace per machine.
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
DEFAULT_ROOT="$HOME/workspace"
APT_SOURCES="${INIT_APT_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where an earlier run remembered the folder the user chose (init is
# resumable across wsl --terminate etc., and the workspace doesn't
# exist yet during those early re-runs). Overridable for init.bats.
STATE_FILE="${INIT_STATE_FILE:-$SCRIPT_DIR/.workspace-root}"
PROC_VERSION="${INIT_PROC_VERSION:-/proc/version}"
# WORKSPACE_ROOT, ROOT_SOURCE, RUN_SH are set by resolve_root, below.

is_wsl() {
  # WSL2's kernel identifies itself here; real Ubuntu (bare metal,
  # a plain VM, a cloud box) never matches this. Getting this wrong
  # matters: 127.0.0.53 (systemd-resolved) is the NORMAL, healthy
  # default on real Ubuntu — it's only broken under WSL because its
  # upstream is a dead NAT proxy specific to that environment. Without
  # this gate, init would "fix" DNS that was never broken.
  grep -qi microsoft "$PROC_VERSION" 2>/dev/null
}

usage() {
  echo "Usage: $(basename "$0") [--check] [--dir <path>]"
  echo "  --check       report only: change nothing, always exit 0"
  echo "  --dir <path>  where the workspace lives (a bare name goes under ~);"
  echo "                default ~/workspace, asked interactively when not given"
}

MODE="--interactive"
ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--interactive) MODE="$1" ;;
    --dir)   [ $# -ge 2 ] || { usage; exit 1; }; ROOT_ARG="$2"; shift ;;
    --dir=*) ROOT_ARG="${1#--dir=}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

# ══ Workspace root — where it lives, how it's chosen, what's refused ═

# $1 = what the user typed / passed -> absolute path on stdout.
# Empty = the default; a bare name goes under $HOME; ~/x and ./x work.
normalize_root() {
  local in="$1"
  case "$in" in
    "")    in="$DEFAULT_ROOT" ;;
    "~")   in="$HOME" ;;
    "~/"*) in="$HOME/${in#"~/"}" ;;
    /*)    ;;
    .|..|*/*) in="$PWD/$in" ;;
    *)     in="$HOME/$in" ;;
  esac
  realpath -m -- "$in"
}

# Prints a one-line reason and returns 1 if $1 can't be the workspace
# root; prints nothing and returns 0 if it can. It looks at what the
# folder IS, never at what it's called — any name is fine.
root_problem() {
  local r="$1" real_home entries
  real_home="$(realpath -m -- "$HOME")"
  [ "$r" != "/" ] || { echo "that is the filesystem root"; return 1; }
  # the default root keeps working exactly as before, whatever $HOME looks like
  if [ "$r" != "$real_home/workspace" ] && ! [[ "$r" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "use an absolute path with only letters, digits, . _ - / (no spaces)"; return 1
  fi
  case "$real_home/" in
    "$r"/*) echo "that is your home folder (or contains it) — pick a dedicated folder"; return 1 ;;
  esac
  case "$r" in
    /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|/libx32|/libx32/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*)
      echo "that is a system directory"; return 1 ;;
    /mnt/[a-z]|/mnt/[a-z]/*)
      echo "Windows drives (/mnt/c, ...) break chmod 700 on secrets and are slow — use a folder in the Linux filesystem"; return 1 ;;
  esac
  if [ -e "$r" ] && [ ! -d "$r" ]; then
    echo "it exists and is not a folder"; return 1
  fi
  # An existing folder must be empty (apart from the staged init files
  # and the workspace's own top-level folders, e.g. a models/ left over
  # from a previous install) or already be a workspace — never dump a
  # workspace into someone's unrelated folder.
  if [ -d "$r" ] && [ ! -x "$r/infrastructure/scripts/run.sh" ]; then
    entries="$(ls -A "$r" 2>/dev/null \
      | grep -vxE 'init|init\.sh|init\.bats|setup\.sh|setup\.bats|migrate_docker_backend\.sh|\.workspace-root|projects|vault|ai|infrastructure|models|backups|archives|\.vscode' \
      | head -5 | tr '\n' ' ')"
    [ -z "$entries" ] || { echo "the folder exists and isn't empty (has: ${entries% }) — pick an empty or new folder"; return 1; }
  fi
  return 0
}

prompt_root() {
  local ans r problem tries=0
  echo "Where should the workspace live?"
  echo "  Enter = ~/workspace   |   a name (created under ~)   |   or a full path"
  while :; do
    read -r -p "Workspace folder [~/workspace]: " ans || ans=""
    r="$(normalize_root "$ans")"
    if problem="$(root_problem "$r")"; then
      WORKSPACE_ROOT="$r"; ROOT_SOURCE="prompt"; return 0
    fi
    echo "  Can't use $r: $problem"
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || { echo "Too many invalid answers — re-run init.sh."; exit 1; }
  done
}

resolve_root() {
  local parent; parent="$(dirname "$SCRIPT_DIR")"
  if [ -n "${INIT_WORKSPACE_ROOT:-}" ]; then
    WORKSPACE_ROOT="$(normalize_root "$INIT_WORKSPACE_ROOT")"; ROOT_SOURCE="INIT_WORKSPACE_ROOT"
  elif [ -n "$ROOT_ARG" ]; then
    WORKSPACE_ROOT="$(normalize_root "$ROOT_ARG")"; ROOT_SOURCE="--dir"
  elif [ "$(basename "$SCRIPT_DIR")" = "init" ] && [ -d "$parent/infrastructure" ]; then
    WORKSPACE_ROOT="$parent"; ROOT_SOURCE="this script's location"
  elif [ -s "$STATE_FILE" ]; then
    WORKSPACE_ROOT="$(normalize_root "$(head -n1 "$STATE_FILE")")"; ROOT_SOURCE="saved choice"
  elif [ -x "$DEFAULT_ROOT/infrastructure/scripts/run.sh" ]; then
    WORKSPACE_ROOT="$(normalize_root "")"; ROOT_SOURCE="existing install"
  elif [ "$MODE" = "--interactive" ] && { [ -t 0 ] || [ -n "${INIT_ASSUME_TTY:-}" ]; }; then
    prompt_root
  else
    WORKSPACE_ROOT="$(normalize_root "")"; ROOT_SOURCE="default"
  fi

  ROOT_PROBLEM=""
  ROOT_PROBLEM="$(root_problem "$WORKSPACE_ROOT")" && ROOT_PROBLEM=""

  if [ -n "$ROOT_PROBLEM" ] && [ "$MODE" != "--check" ]; then
    echo "init: can't use $WORKSPACE_ROOT as the workspace ($ROOT_SOURCE): $ROOT_PROBLEM" >&2
    exit 1
  fi
  # Remember an explicit choice so the resumable early re-runs (before
  # the workspace exists) don't ask again — or silently fall back to the
  # default if the user just pressed Enter.
  if [ -z "$ROOT_PROBLEM" ] && [ "$MODE" = "--interactive" ] \
     && { [ "$ROOT_SOURCE" = "prompt" ] || [ "$ROOT_SOURCE" = "--dir" ]; }; then
    printf '%s\n' "$WORKSPACE_ROOT" > "$STATE_FILE" 2>/dev/null || true
  fi
  RUN_SH="$WORKSPACE_ROOT/infrastructure/scripts/run.sh"
}

resolve_root

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
  if [ -n "$ROOT_PROBLEM" ]; then
    # only reachable in --check (a real run exits before the scan)
    miss "workspace root $WORKSPACE_ROOT is unusable: $ROOT_PROBLEM"
    note "-> pass --dir <path> (or set INIT_WORKSPACE_ROOT) to pick another"
    return
  fi
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
      propose fix_workspace "run setup.sh (creates the whole workspace at $WORKSPACE_ROOT; needs docker green above)"
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

# Once the workspace exists, COPY the staged init files into
# <root>/init/ so the workspace carries its own copy to re-run from
# (and VS Code tasks can point at it). Copies, never moves: the files
# next to this script stay where they are, so a re-run from either
# place works, and nothing is lost if the workspace is rebuilt.
# Copies only the files this project ships, never the rest of the
# folder they were downloaded into.
stage_into_workspace() {
  local dest="$WORKSPACE_ROOT/init" n=0 f
  local files=(init.sh init.bats setup.sh setup.bats migrate_docker_backend.sh .workspace-root)
  [ "$SCRIPT_DIR" != "$dest" ] || return 0
  mkdir -p "$dest" || { echo "WARNING: could not create $dest — nothing copied."; return 0; }
  for f in "${files[@]}"; do
    [ -f "$SCRIPT_DIR/$f" ] || continue
    cp -f "$SCRIPT_DIR/$f" "$dest/$f"
    n=$((n + 1))
  done
  echo "Copied $n file(s) into $dest — you can re-run init from there or from here."
}

fix_workspace() {
  local rc=0
  INIT_WORKSPACE_ROOT="$WORKSPACE_ROOT" bash "$SCRIPT_DIR/setup.sh" || rc=$?
  [ "$rc" -eq 0 ] || echo "setup.sh exited $rc — see its output above (a failing health check does not undo what it created)."
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

  # Only once the workspace really exists (run.sh is its last piece).
  [ -x "$RUN_SH" ] && stage_into_workspace
  return 0
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

echo "Workspace root: $WORKSPACE_ROOT  [$ROOT_SOURCE]"
[ "$ROOT_SOURCE" != "default" ] || echo "  (not asked: non-interactive or --check; a real run on a TTY asks where)"
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
       echo "Re-run to continue from the next gap:  bash $SCRIPT_DIR/init.sh" ;;
  *)   echo "Nothing changed. Re-run anytime — init always resumes." ;;
esac
