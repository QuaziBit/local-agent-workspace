#!/usr/bin/env bats
#
# init.bats — tests for init.sh's detection logic, runnable standalone
# from the repo folder:  bats init.bats
#
# Same philosophy as setup.bats' migration tests: the actions that
# touch the real OS (apt, systemctl, chattr, wsl.conf) are real-OS
# behavior verified on hardware (Run 3); what IS testable is the
# detection — every check reads env-overridable paths precisely so
# these tests can point them at fixtures. --check must always be
# report-only: exit 0, write nothing.

setup() {
  TEST_HOME="$(mktemp -d)"
  INIT="$BATS_TEST_DIRNAME/init.sh"
  export INIT_SECRETS_DIR="$TEST_HOME/.secrets"
  export INIT_WORKSPACE_ROOT="$TEST_HOME/workspace"
  export INIT_WSL_CONF="$TEST_HOME/wsl.conf"
  export INIT_RESOLV_CONF="$TEST_HOME/resolv.conf"
  export INIT_APT_SOURCES="$TEST_HOME/ubuntu.sources"
  # Default: simulate real Ubuntu (no "microsoft" in /proc/version).
  # Tests that need WSL behavior override this explicitly.
  echo "Linux version 6.8.0-generic (buildd@ubuntu) #1 SMP" > "$TEST_HOME/proc_version_real"
  export INIT_PROC_VERSION="$TEST_HOME/proc_version_real"
}

teardown() { rm -rf "$TEST_HOME"; }

@test "init.sh passes shell syntax check" {
  run bash -n "$INIT"
  [ "$status" -eq 0 ]
}

@test "--check always exits 0, even on a completely bare machine" {
  run bash "$INIT" --check
  [ "$status" -eq 0 ]
}

@test "--check writes nothing" {
  local before after
  before="$(find "$TEST_HOME" | sort)"
  run bash "$INIT" --check
  after="$(find "$TEST_HOME" | sort)"
  [ "$before" = "$after" ]
}

@test "detects the symlinked resolv.conf (DNS demon form 1) — WSL only, gated by is_wsl" {
  wsl_proc_version
  touch "$TEST_HOME/target"
  ln -s "$TEST_HOME/target" "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"resolv.conf is a symlink"* ]]
}

@test "detects the WSL proxy nameserver 10.255.255.254 — WSL only, gated by is_wsl" {
  wsl_proc_version
  echo "nameserver 10.255.255.254" > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"10.255.255.254"* ]]
  [[ "$output" == *"MISS"* ]]
}

@test "detects systemd-resolved's stub 127.0.0.53 (form 2) — WSL only; healthy off-WSL, see the dedicated WSL-detection tests below" {
  wsl_proc_version
  echo "nameserver 127.0.0.53" > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"127.0.0.53"* ]]
}

@test "a static public-resolver resolv.conf reads OK on WSL (lock status warned separately)" {
  wsl_proc_version
  printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"resolv.conf is a static file"* ]]
}

@test "windows interop docker leakage is named, not called native" {
  local w="$TEST_HOME/mnt/c/Program Files/Docker/Docker/resources/bin"
  mkdir -p "$w" "$TEST_HOME/bin"
  printf '#!/bin/sh\ntrue\n' > "$w/docker"; chmod +x "$w/docker"
  ln -sf "$w/docker" "$TEST_HOME/bin/docker"
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"interop"* ]]
}

@test "missing workspace is reported, and its fix is wired to the staged setup.sh" {
  # init.sh and setup.sh live in the same dir in the repo — they do here too
  [ -f "$BATS_TEST_DIRNAME/setup.sh" ]
  run bash "$INIT" --check
  [[ "$output" == *"no bootstrapped workspace yet"* ]]
  # The proposal LABEL only surfaces when this is the FIRST gap —
  # propose() is first-gap-only by design, and in this bare fixture
  # the wsl.conf gap wins. So verify the wiring statically instead:
  grep -q 'propose fix_workspace "run setup.sh' "$INIT"
  grep -q 'bash "\$SCRIPT_DIR/setup.sh"' "$INIT"
}

@test "missing credentials are reported; present ones read OK" {
  run bash "$INIT" --check
  [[ "$output" == *"no Claude Code credential"* ]]
  [[ "$output" == *"no Codex credential"* ]]
  mkdir -p "$INIT_SECRETS_DIR/claude-home" "$INIT_SECRETS_DIR/codex-home"
  echo '{"t":"x"}' > "$INIT_SECRETS_DIR/claude-home/.credentials.json"
  echo '{"auth_mode":"chatgpt"}' > "$INIT_SECRETS_DIR/codex-home/auth.json"
  run bash "$INIT" --check
  [[ "$output" == *"Claude Code credential on disk"* ]]
  [[ "$output" == *"Codex credential on disk"* ]]
}

@test "missing model override warns about the expensive default" {
  mkdir -p "$INIT_SECRETS_DIR/claude-home"
  run bash "$INIT" --check
  [[ "$output" == *"MOST EXPENSIVE model"* ]]
}

@test "hermes order rule: dashboard_auth deferred until a provider exists" {
  mkdir -p "$INIT_SECRETS_DIR/hermes-home"
  echo "some: yaml" > "$INIT_SECRETS_DIR/hermes-home/config.yaml"
  run bash "$INIT" --check
  [[ "$output" == *"deferred until after 'hermes setup'"* ]]
}

@test "the wsl.conf template carries all four sections" {
  grep -q "systemd=true" "$INIT"
  grep -q "appendWindowsPath=false" "$INIT"
  grep -q "generateResolvConf=false" "$INIT"
  grep -q "^default=" "$INIT" || grep -q 'default=\$me' "$INIT"
}

@test "the durable DNS fix handles an existing chattr lock" {
  # regression guard for the lock-then-refix scenario: chattr -i must
  # precede the rm, or a locked file makes the fix impossible
  grep -q "chattr -i" "$INIT"
  grep -q "chattr +i" "$INIT"
}

# ── WSL detection — 127.0.0.53 is healthy on real Ubuntu ─
# systemd-resolved's stub resolver is the NORMAL default off-WSL; it's
# only broken under WSL because its upstream is a dead NAT proxy
# specific to that environment. Getting this gate wrong means init
# "fixing" DNS that was never broken — these tests exist because a
# desktop/real-OS install surfaced exactly that risk before it shipped.

wsl_proc_version() {
  echo "Linux version 5.15.167.4-microsoft-standard-WSL2" > "$TEST_HOME/proc_version_wsl"
  export INIT_PROC_VERSION="$TEST_HOME/proc_version_wsl"
}

@test "127.0.0.53 is NOT flagged as broken on simulated real Ubuntu (non-WSL)" {
  printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" != *"systemd-resolved's stub"* ]]
  [[ "$output" == *"not WSL — skipping wsl.conf checks"* ]]
}

@test "127.0.0.53 IS still flagged as broken on simulated WSL" {
  wsl_proc_version
  printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"systemd-resolved's stub 127.0.0.53"* ]]
}

@test "wsl.conf checks run normally on WSL with a real wsl.conf present" {
  wsl_proc_version
  cat > "$INIT_WSL_CONF" << 'EOF'
[boot]
systemd=true
[network]
generateResolvConf=false
[interop]
appendWindowsPath=false
EOF
  printf 'nameserver 1.1.1.1\n' > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"wsl.conf disables resolv.conf generation"* ]]
  [[ "$output" == *"wsl.conf strips the Windows interop PATH"* ]]
}

@test "fix_dns refuses to run on non-WSL rather than disabling a healthy resolver" {
  grep -q 'REFUSING.*systemd-resolved permanently' "$INIT"
  grep -q '! is_wsl' "$INIT"
}

@test "a live DNS probe still runs on non-WSL — this isn't a blanket skip, just no WSL-specific tells" {
  printf 'nameserver 127.0.0.53\n' > "$INIT_RESOLV_CONF"
  run bash "$INIT" --check
  [[ "$output" == *"DNS resolves (download.docker.com)"* || "$output" == *"DNS does not resolve"* ]]
}

# ── apt/network check is PROBE-based, not file-existence-based ─
# The original version unconditionally WARNed about missing https/IPv4
# mitigations regardless of whether THIS network actually has the
# problem — same class of bug as the DNS false-positive, just milder.
# Fixed to test what apt would actually experience right now.

mock_curl() {
  # $1 = fast|slow|fail
  mkdir -p "$TEST_HOME/bin"
  case "$1" in
    fast) printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/bin/curl" ;;
    slow) printf '#!/bin/bash\nsleep 3.5\nexit 0\n' > "$TEST_HOME/bin/curl" ;;
    fail) printf '#!/bin/bash\nexit 1\n' > "$TEST_HOME/bin/curl" ;;
  esac
  chmod +x "$TEST_HOME/bin/curl"
}

@test "apt/network: fast http probe is OK, no fix proposed" {
  echo "URIs: http://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl fast
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"apt mirror (http) responds fine"* ]]
  [[ "$output" != *"Next step: switch apt to https"* ]]
}

@test "apt/network: slow http probe warns AND proposes the fix" {
  echo "URIs: http://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl slow
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"apt mirror (http) is slow"* ]]
  [[ "$output" == *"switch apt to https mirrors + pin IPv4"* ]]
}

@test "apt/network: failed http probe warns AND proposes the fix" {
  echo "URIs: http://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl fail
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"connection failed or stalled"* ]]
  [[ "$output" == *"switch apt to https mirrors + pin IPv4"* ]]
}

@test "apt/network: already-mitigated (https) and fast is OK, no fix proposed" {
  echo "URIs: https://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl fast
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"apt mirror (https) responds fine"* ]]
  [[ "$output" != *"Next step: switch apt to https"* ]]
}

@test "apt/network: already-mitigated (https) but STILL slow does NOT re-propose the same fix" {
  echo "URIs: https://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl slow
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"deeper network issue than the known fix addresses"* ]]
  [[ "$output" != *"Next step: switch apt to https"* ]]
}

@test "apt/network check works identically on WSL and non-WSL (not platform-gated, unlike DNS)" {
  wsl_proc_version
  echo "URIs: http://archive.ubuntu.com/ubuntu/" > "$INIT_APT_SOURCES"
  mock_curl slow
  PATH="$TEST_HOME/bin:$PATH" run bash "$INIT" --check
  [[ "$output" == *"apt mirror (http) is slow"* ]]
}

# --- fix_workspace auto-copies setup.sh/setup.bats into bootstrap ---

@test "fix_workspace copies (not moves) setup.sh + setup.bats into infrastructure/bootstrap" {
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -q 'cp -f \"\$SCRIPT_DIR/\$f\" \"\$boot_dir/\$f\"'"
  [ "$status" -eq 0 ]
}

@test "fix_workspace's copy is non-destructive: staged files must still exist afterward" {
  # the drift-compare a few lines above fix_workspace (ws_setup vs
  # SCRIPT_DIR/setup.sh) and the next --check run both depend on the
  # staged copy surviving — this is a regression guard against ever
  # swapping cp for mv here.
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -qE '^\s*mv .*setup\.(sh|bats)'"
  [ "$status" -eq 1 ]
}

@test "fix_workspace creates the bootstrap dir if it doesn't exist yet" {
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -q 'mkdir -p \"\$boot_dir\"'"
  [ "$status" -eq 0 ]
}

@test "fix_workspace warns instead of silently no-op-ing when nothing is staged to copy" {
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -q 'WARNING: setup.sh/setup.bats not found'"
  [ "$status" -eq 0 ]
}
