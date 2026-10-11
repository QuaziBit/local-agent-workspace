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

# ── Workspace root: choosing it, resolving it, refusing bad ones ──
# The workspace folder can be named anything and live anywhere sane:
# init.sh asks (default ~/workspace), accepts --dir, remembers the
# answer, and refuses places that must never become a workspace.
# setup() exports INIT_WORKSPACE_ROOT for the older tests above; these
# use `env -u` to exercise the REAL resolution order instead. The
# prompt itself is exercised through INIT_ASSUME_TTY (bats has no TTY).
# NOTE: every negative assertion here is a [[ != ]] on purpose — a
# mid-test `! grep` never fails a bats test.

init_as_home() {
  env -u INIT_WORKSPACE_ROOT HOME="$TEST_HOME" INIT_STATE_FILE="$TEST_HOME/state" "$@"
}

# feed $1 to the prompt as typed input, then 'n' to the final "Do it now?"
init_prompted() {
  local typed="$1"; shift
  run bash -c 'printf "%s\nn\n" "$1" | INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$2" INIT_STATE_FILE="$2/state" bash "$3" "${@:4}"' _ "$typed" "$TEST_HOME" "$INIT" "$@"
}

@test "root: with nothing else to go on (non-interactive), the default is ~/workspace" {
  run init_as_home bash "$INIT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace root: $TEST_HOME/workspace  [default]"* ]]
}

@test "root: --dir with a bare name resolves under ~" {
  run init_as_home bash "$INIT" --check --dir ai-lab
  [[ "$output" == *"Workspace root: $TEST_HOME/ai-lab  [--dir]"* ]]
}

@test "root: --dir accepts a full path, a relative path, ~/x and the --dir=x form" {
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME/some/where"
  [[ "$output" == *"Workspace root: $TEST_HOME/some/where  [--dir]"* ]]
  cd "$TEST_HOME"
  run init_as_home bash "$INIT" --check --dir ./rel/ws
  [[ "$output" == *"Workspace root: $TEST_HOME/rel/ws  [--dir]"* ]]
  run init_as_home bash "$INIT" --check --dir '~/tilde-ws'
  [[ "$output" == *"Workspace root: $TEST_HOME/tilde-ws  [--dir]"* ]]
  run init_as_home bash "$INIT" --check --dir=eq-ws
  [[ "$output" == *"Workspace root: $TEST_HOME/eq-ws  [--dir]"* ]]
}

@test "root: INIT_WORKSPACE_ROOT beats --dir" {
  run env INIT_WORKSPACE_ROOT="$TEST_HOME/fromenv" HOME="$TEST_HOME" INIT_STATE_FILE="$TEST_HOME/state" \
    bash "$INIT" --check --dir other
  [[ "$output" == *"Workspace root: $TEST_HOME/fromenv  [INIT_WORKSPACE_ROOT]"* ]]
}

@test "root: an existing ~/workspace install is used without asking" {
  mkdir -p "$TEST_HOME/workspace/infrastructure/scripts"
  printf '#!/bin/sh\n' > "$TEST_HOME/workspace/infrastructure/scripts/run.sh"
  chmod +x "$TEST_HOME/workspace/infrastructure/scripts/run.sh"
  run bash -c 'INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$1" INIT_STATE_FILE="$1/state" bash "$2" </dev/null' _ "$TEST_HOME" "$INIT"
  [[ "$output" == *"Workspace root: $TEST_HOME/workspace  [existing install]"* ]]
  [[ "$output" != *"Where should the workspace live"* ]]
}

@test "root: a script sitting in <root>/init/ uses that root (no flag, no question)" {
  mkdir -p "$TEST_HOME/lab/init" "$TEST_HOME/lab/infrastructure"
  cp "$INIT" "$TEST_HOME/lab/init/init.sh"
  run bash -c 'INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$1" bash "$1/lab/init/init.sh" --check </dev/null' _ "$TEST_HOME"
  [[ "$output" == *"Workspace root: $TEST_HOME/lab  [this script's location]"* ]]
}

@test "root: a choice saved by an earlier run is reused" {
  echo "$TEST_HOME/saved-ws" > "$TEST_HOME/state"
  run init_as_home bash "$INIT" --check
  [[ "$output" == *"Workspace root: $TEST_HOME/saved-ws  [saved choice]"* ]]
}

# ── the prompt ───────────────────────────────────────────────────

@test "prompt: a bare name is created under ~, remembered, and not asked again" {
  init_prompted "ai-lab"
  [[ "$output" == *"Where should the workspace live?"* ]]
  [[ "$output" == *"Workspace root: $TEST_HOME/ai-lab  [prompt]"* ]]
  [ "$(cat "$TEST_HOME/state")" = "$TEST_HOME/ai-lab" ]
  # the resumable re-run (e.g. after wsl --terminate) must not ask again
  # or fall back to the default
  run bash -c 'printf "n\n" | INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$1" INIT_STATE_FILE="$1/state" bash "$2"' _ "$TEST_HOME" "$INIT"
  [[ "$output" == *"Workspace root: $TEST_HOME/ai-lab  [saved choice]"* ]]
  [[ "$output" != *"Where should the workspace live"* ]]
}

@test "prompt: Enter alone takes ~/workspace" {
  init_prompted ""
  [[ "$output" == *"Workspace root: $TEST_HOME/workspace  [prompt]"* ]]
}

@test "prompt: a full path works" {
  init_prompted "$TEST_HOME/deep/er/ws"
  [[ "$output" == *"Workspace root: $TEST_HOME/deep/er/ws  [prompt]"* ]]
}

@test "prompt: an unusable answer is explained and the question repeats" {
  run bash -c 'printf "/\nai-lab\nn\n" | INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$1" INIT_STATE_FILE="$1/state" bash "$2"' _ "$TEST_HOME" "$INIT"
  [[ "$output" == *"Can't use /: that is the filesystem root"* ]]
  [[ "$output" == *"Workspace root: $TEST_HOME/ai-lab  [prompt]"* ]]
}

@test "prompt: never appears in --check, and --check saves nothing" {
  run bash -c 'printf "ai-lab\n" | INIT_ASSUME_TTY=1 env -u INIT_WORKSPACE_ROOT HOME="$1" INIT_STATE_FILE="$1/state" bash "$2" --check' _ "$TEST_HOME" "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Where should the workspace live"* ]]
  [[ "$output" == *"[default]"* ]]
  [ ! -e "$TEST_HOME/state" ]
}

@test "--check --dir writes nothing at all (no folder, no saved choice)" {
  local before after
  before="$(find "$TEST_HOME" | sort)"
  run init_as_home bash "$INIT" --check --dir ai-lab
  after="$(find "$TEST_HOME" | sort)"
  [ "$before" = "$after" ]
}

@test "a real run with --dir remembers the choice" {
  run bash -c 'printf "n\n" | env -u INIT_WORKSPACE_ROOT HOME="$1" INIT_STATE_FILE="$1/state" bash "$2" --dir ai-lab' _ "$TEST_HOME" "$INIT"
  [ "$(cat "$TEST_HOME/state")" = "$TEST_HOME/ai-lab" ]
}

# ── the guards: judge the folder, never its name ─────────────────

@test "guards: places that must never become a workspace are named in --check and refused in a real run" {
  touch "$TEST_HOME/afile"
  mkdir -p "$TEST_HOME/busy" && touch "$TEST_HOME/busy/notes.txt"
  local bad
  local bad_roots=("/" "$TEST_HOME" "/usr/local/ws" "/mnt/c/Users/x" "$TEST_HOME/has space" "$TEST_HOME/afile" "$TEST_HOME/busy")
  for bad in "${bad_roots[@]}"; do
    run init_as_home bash "$INIT" --check --dir "$bad"
    [ "$status" -eq 0 ]                     # --check always exits 0
    [[ "$output" == *"is unusable"* ]]
    run init_as_home bash "$INIT" --dir "$bad"
    [ "$status" -eq 1 ]                     # a real run stops before doing anything
    [[ "$output" == *"can't use"* ]]
  done
  [ ! -e "$TEST_HOME/has space" ]
}

@test "guards: the reasons are specific (home, Windows drive, non-empty, spaces)" {
  mkdir -p "$TEST_HOME/busy" && touch "$TEST_HOME/busy/notes.txt"
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME"
  [[ "$output" == *"your home folder"* ]]
  run init_as_home bash "$INIT" --check --dir /mnt/c/Users/x
  [[ "$output" == *"Windows drives"* ]]
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME/busy"
  [[ "$output" == *"isn't empty (has: notes.txt)"* ]]
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME/has space"
  [[ "$output" == *"no spaces"* ]]
}

@test "guards: odd-but-sane names, an existing workspace, and a folder of only staged files are all accepted" {
  mkdir -p "$TEST_HOME/lab/infrastructure/scripts"
  printf '#!/bin/sh\n' > "$TEST_HOME/lab/infrastructure/scripts/run.sh"
  chmod +x "$TEST_HOME/lab/infrastructure/scripts/run.sh"
  mkdir -p "$TEST_HOME/staged" && touch "$TEST_HOME/staged"/{init.sh,setup.sh,setup.bats,init.bats,migrate_docker_backend.sh}
  local ok
  for ok in "$TEST_HOME/workspace" "$TEST_HOME/my-ai_lab.2" "$TEST_HOME/dev" "$TEST_HOME/lab" "$TEST_HOME/staged"; do
    run init_as_home bash "$INIT" --check --dir "$ok"
    [[ "$output" != *"is unusable"* ]]
  done
}

@test "guards: leftovers from a previous install (models/, backups/ ...) don't block the folder, a stray file still does" {
  mkdir -p "$TEST_HOME/old/models/ollama" "$TEST_HOME/old/backups" "$TEST_HOME/old/vault"
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME/old"
  [[ "$output" != *"is unusable"* ]]
  touch "$TEST_HOME/old/notes.txt"
  run init_as_home bash "$INIT" --check --dir "$TEST_HOME/old"
  [[ "$output" == *"isn't empty (has: notes.txt)"* ]]
}

# ── staging: copy the shipped files into <root>/init/ ────────────

stage_run() {   # $1 = source dir, $2 = workspace root
  bash -c "
    SCRIPT_DIR='$1'; WORKSPACE_ROOT='$2'
    $(sed -n '/^stage_into_workspace() {/,/^}/p' "$INIT")
    stage_into_workspace
    echo \"SCRIPT_DIR=\$SCRIPT_DIR\"
  "
}

@test "staging: the shipped files are COPIED into <root>/init/; originals and unrelated files stay" {
  local dl="$TEST_HOME/download" root="$TEST_HOME/ai-lab"
  mkdir -p "$dl" && touch "$dl"/{init.sh,init.bats,setup.sh,setup.bats,migrate_docker_backend.sh,keepme.txt}
  run stage_run "$dl" "$root"
  [ "$status" -eq 0 ]
  for f in init.sh init.bats setup.sh setup.bats migrate_docker_backend.sh; do
    [ -f "$root/init/$f" ]
    [ -f "$dl/$f" ]
  done
  [ -f "$dl/keepme.txt" ]
  [ ! -e "$root/init/keepme.txt" ]
  [[ "$output" == *"SCRIPT_DIR=$dl"* ]]
}

@test "staging: works the same from a git checkout, and nothing in the repo changes" {
  local repo="$TEST_HOME/repo" root="$TEST_HOME/ai-lab"
  mkdir -p "$repo/scripts" && git -C "$repo" init -q
  touch "$repo/scripts"/{init.sh,setup.sh}
  git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm x
  run stage_run "$repo/scripts" "$root"
  [ -f "$repo/scripts/init.sh" ]
  [ -f "$repo/scripts/setup.sh" ]
  [ -f "$root/init/init.sh" ]
  [ -z "$(git -C "$repo" status --porcelain)" ]
}

@test "staging: no mv of the shipped files anywhere in stage_into_workspace" {
  run bash -c "sed -n '/^stage_into_workspace() {/,/^}/p' '$INIT' | grep -E '(^|[^a-z_])mv '"
  [ "$status" -ne 0 ]
}

@test "staging: already running from <root>/init/ is a no-op" {
  local root="$TEST_HOME/ai-lab"
  mkdir -p "$root/init" && touch "$root/init"/{init.sh,setup.sh}
  run stage_run "$root/init" "$root"
  [ "$status" -eq 0 ]
  [ -f "$root/init/init.sh" ]
  [[ "$output" != *"Copied"* ]]
}

@test "fix_workspace hands setup.sh the chosen root and stages only once the workspace exists" {
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -q 'INIT_WORKSPACE_ROOT=\"\$WORKSPACE_ROOT\" bash \"\$SCRIPT_DIR/setup.sh\"'"
  [ "$status" -eq 0 ]
  run bash -c "sed -n '/^fix_workspace() {/,/^}/p' '$INIT' | grep -q '\[ -x \"\$RUN_SH\" \] && stage_into_workspace'"
  [ "$status" -eq 0 ]
}
