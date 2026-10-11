#!/usr/bin/env bash
#
# migrate_docker_backend.sh — move the stack between Docker Desktop's
# WSL backend and native docker-ce inside this Ubuntu distro.
#
# Why this exists: fewer standing apps on the laptop. Docker Desktop
# stays INSTALLED (needed for non-stack use) — this only changes
# which daemon this distro's `docker` talks to. The switch is
# deliberately reversible: nothing in the stack depends on docker-ce
# specifics (compose files, run.sh, tasks.json are daemon-agnostic),
# and --revert uninstalls nothing.
#
# Usage (or via run.sh docker_status / docker_migrate / docker_revert):
#   migrate_docker_backend.sh [--check]    read-only status (default)
#   migrate_docker_backend.sh --migrate    install/enable native docker-ce
#   migrate_docker_backend.sh --revert     back to the Docker Desktop shim
#
# What this script CANNOT do (honest limits, decided in advance):
#   - Flip Docker Desktop's "WSL integration" toggle — that's a
#     Windows GUI setting (Settings → Resources → WSL integration).
#     The script detects it and tells you, but you flip it.
#   - Purge the stack's images from Desktop's side — with integration
#     off, Desktop's daemon isn't reachable from this distro at all.
#     Do it in Desktop's own UI, and only after the native path has
#     survived real day-to-day use for a while (features.md entry).

set -uo pipefail   # not -e: --check must report everything, not stop

# ── Detection helpers (PATH-based, so bats can mock them) ─────────

docker_cli_path() {
  local p
  p="$(command -v docker 2>/dev/null || true)"
  [ -n "$p" ] || { echo ""; return; }
  readlink -f "$p" 2>/dev/null || echo "$p"
}

docker_flavor() {
  # "desktop"  — CLI resolves into Docker Desktop's injected tooling
  # "native"   — a real binary in the distro (docker-ce)
  # "none"     — no docker CLI on PATH at all
  local p; p="$(docker_cli_path)"
  [ -n "$p" ] || { echo "none"; return; }
  case "$p" in
    */docker-desktop/*|*/mnt/wsl/*) echo "desktop" ;;
    # Windows PATH interop leakage: no docker IN the distro, but
    # WSL's appended Windows PATH exposes Desktop's Windows-side CLI
    # under /mnt/<drive>/ (found on a virgin distro —
    # running it just prints Desktop's "activate WSL integration"
    # stub). Not a real backend; treat as "nothing installed here."
    */mnt/[a-z]/*) echo "windows-interop" ;;
    *) echo "native" ;;
  esac
}

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

yn() { local a; read -r -p "$1 [y/N] " a; case "$a" in y|Y) return 0;; *) return 1;; esac; }

# ── --check ───────────────────────────────────────────────────────

do_check() {
  local p flavor
  p="$(docker_cli_path)"; flavor="$(docker_flavor)"

  echo "== Docker backend status =="
  case "$flavor" in
    desktop) echo "  Docker CLI: $p  (Docker Desktop shim)" ;;
    native)  echo "  Docker CLI: $p  (native docker-ce)" ;;
    windows-interop)
      echo "  Docker CLI: $p"
      echo "              (Desktop's WINDOWS CLI via interop PATH —"
      echo "               no docker is installed in this distro)" ;;
    none)    echo "  Docker CLI: not on PATH" ;;
  esac
  # The CLI path alone can lie in the hybrid state: --revert keeps
  # docker-ce installed, so /usr/bin/docker stays on PATH even when
  # Desktop's proxy is the one serving /var/run/docker.sock. Ask the
  # daemon itself who it is (best-effort; needs a reachable daemon).
  if [ "$flavor" != "none" ] && [ "$flavor" != "windows-interop" ]; then
    local dsays; dsays="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
    if [ -n "$dsays" ]; then
      echo "  Daemon:     $dsays"
    else
      echo "  Daemon:     not reachable (nothing serving the socket)"
    fi
  fi

  echo "== Migration prerequisites =="
  if [ -d /run/systemd/system ]; then
    echo "  OK    systemd is running in this distro"
  else
    echo "  MISS  systemd not running — needs [boot] systemd=true in /etc/wsl.conf + wsl --shutdown"
  fi
  if grep -qs "systemd[[:space:]]*=[[:space:]]*true" /etc/wsl.conf 2>/dev/null; then
    echo "  OK    /etc/wsl.conf enables systemd"
  else
    echo "  MISS  /etc/wsl.conf does not set systemd=true"
  fi
  for pkg in docker-ce docker-compose-plugin nvidia-container-toolkit; do
    if have_pkg "$pkg"; then echo "  OK    $pkg installed"
    else echo "  MISS  $pkg not installed"; fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    # is-active prints its state AND exits non-zero for anything but
    # "active" — capture with || true so the fallback doesn't double-print
    local svc; svc="$(systemctl is-active docker 2>/dev/null || true)"
    echo "  ....  native docker service: ${svc:-unknown}"
  fi
  local me; me="${USER:-$(id -un)}"
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    echo "  OK    $me is in the docker group"
  else
    echo "  MISS  $me not in the docker group (needs re-login after usermod)"
  fi

  echo
  case "$flavor" in
    desktop)
      echo "Currently on the DESKTOP backend. To migrate: flip the WSL"
      echo "integration toggle OFF for this distro first, then --migrate."
      ;;
    native)  echo "Currently on the NATIVE backend. --revert switches back." ;;
    windows-interop)
      echo "No docker inside this distro — only Windows interop leakage."
      echo "Run --migrate to install native docker-ce (it will shadow"
      echo "the Windows CLI on PATH)."
      ;;
    none)
      echo "No docker CLI found — either enable Desktop's WSL integration"
      echo "or run --migrate to install native docker-ce."
      ;;
  esac
}

# ── --migrate ─────────────────────────────────────────────────────

do_migrate() {
  local flavor; flavor="$(docker_flavor)"

  if [ "$flavor" = "windows-interop" ]; then
    echo "NOTE: only Desktop's Windows CLI leaks through the interop"
    echo "PATH — no docker in this distro. Proceeding with the native"
    echo "install; /usr/bin/docker will shadow the leak afterward."
  fi
  if [ "$flavor" = "desktop" ]; then
    echo "REFUSING: docker still resolves to the Docker Desktop shim:"
    echo "  $(docker_cli_path)"
    echo
    echo "Flip the toggle first (Windows side, GUI only — no script can):"
    echo "  Docker Desktop → Settings → Resources → WSL integration"
    echo "  → turn OFF for this distro → Apply & Restart"
    echo "Then open a NEW terminal and re-run: run.sh docker_migrate"
    return 1
  fi

  if [ ! -d /run/systemd/system ]; then
    echo "REFUSING: systemd isn't running in this distro."
    echo "Add to /etc/wsl.conf:"
    echo "  [boot]"
    echo "  systemd=true"
    echo "Then from Windows PowerShell:  wsl --shutdown"
    echo "Reopen the distro and re-run: run.sh docker_migrate"
    return 1
  fi

  # Idempotent install — each step skips if already satisfied, so
  # re-running after a partial failure is safe (same philosophy as
  # setup.sh's "exists, skipping").
  if ! have_pkg docker-ce; then
    echo "== Installing docker-ce (official apt repo) =="
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  else
    echo "  exists, skipping: docker-ce"
  fi

  if ! have_pkg nvidia-container-toolkit; then
    # REQUIRED with native docker-ce: the "no Container Toolkit
    # needed" note in ollama.yaml was true only via Docker Desktop,
    # which bundles the GPU runtime.
    echo "== Installing nvidia-container-toolkit =="
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
  else
    echo "  exists, skipping: nvidia-container-toolkit"
  fi

  echo "== Enabling the native docker service =="
  # a prior --revert masks the unit so WSL restarts can't resurrect
  # it — unmask before enabling or both commands fail
  sudo systemctl unmask docker docker.socket 2>/dev/null || true
  # enable + RESTART, not `enable --now`: the apt install already
  # started dockerd, and --now is a no-op on a running service — so
  # the daemon would never re-read the daemon.json nvidia-ctk just
  # wrote, and GPU containers fail with "could not select device
  # driver nvidia" (hit for real on first migration).
  sudo systemctl enable docker
  sudo systemctl restart docker

  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    local me; me="${USER:-$(id -un)}"
    sudo usermod -aG docker "$me"
    echo "  Added $me to the docker group — takes effect on next"
    echo "  login (or: newgrp docker for this shell only)."
  fi

  echo
  echo "== Verifying with the stack's own tooling =="
  local SCRIPT_DIR; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$SCRIPT_DIR/run.sh" health || true
  bash "$SCRIPT_DIR/run.sh" drift  || true

  echo
  echo "== Done. Next steps (manual, in order) =="
  echo "  1. Confirm: which docker  → /usr/bin/docker, NOT /mnt/wsl/..."
  echo "  2. bats setup.bats — full regression"
  echo "  3. run.sh hermes_claude — one real delegation proves the"
  echo "     credential mounts (images rebuild on first use; models"
  echo "     under \${MODELS_DIR} survive, no re-download)"
  echo "  4. Turn OFF Docker Desktop's autostart (Settings → General)"
  echo "  5. Do NOT purge Desktop's stack copies yet — only after the"
  echo "     native path survives real day-to-day use (features.md)."
  echo "     Purging happens in Desktop's own UI; it's unreachable"
  echo "     from here with integration off."
}

# ── --revert ──────────────────────────────────────────────────────

do_revert() {
  # Reversible switch, never a burned bridge: stop/disable the
  # native service so Desktop's shim wins the PATH again. Nothing
  # is uninstalled — docker-ce stays for the next --migrate.
  echo "== Reverting to the Docker Desktop backend =="
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now docker docker.socket 2>/dev/null || true
    # MASK, not just disable — Desktop's "Apply & Restart" bounces
    # the whole WSL distro, and a merely-disabled unit came back
    # enabled+active through that cycle on real hardware
    #. Masking survives boots; migrate unmasks.
    sudo systemctl mask docker docker.socket 2>/dev/null || true
    # Report ACTUAL state, never assert success — the first version
    # printed "stopped and disabled" unconditionally with stderr
    # suppressed, which hid exactly this failure.
    local en ac
    en="$(systemctl is-enabled docker 2>/dev/null || true)"
    ac="$(systemctl is-active docker 2>/dev/null || true)"
    echo "  native docker service now: ${ac:-unknown} / ${en:-unknown} (still installed)"
    case "$en" in
      masked) : ;;
      *) echo "  WARNING: expected 'masked' — check manually before relying on the revert" ;;
    esac
  fi
  echo
  echo "Now flip the toggle back (Windows side, GUI only):"
  echo "  Docker Desktop → Settings → Resources → WSL integration"
  echo "  → turn ON for this distro → Apply & Restart"
  echo "Then open a NEW terminal and confirm:"
  echo "  which docker   → should resolve into the Desktop shim again"
  echo "The same compose files rebuild under Desktop unchanged — all"
  echo "state lives in the same bind mounts either way."
}

# ── Entry ─────────────────────────────────────────────────────────

case "${1:---check}" in
  --check)   do_check ;;
  --migrate) do_migrate ;;
  --revert)  do_revert ;;
  *) echo "Usage: $(basename "$0") [--check|--migrate|--revert]"; exit 1 ;;
esac
