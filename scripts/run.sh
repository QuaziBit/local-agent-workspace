#!/usr/bin/env bash
#
# run.sh — post-setup convenience runner
#
# Lives at infrastructure/scripts/run.sh AFTER setup.sh has created
# the workspace — this script never creates anything, it only runs
# what already exists. Single source of truth for every "how do I
# start X again?" invocation: the terminal uses it directly, and
# .vscode/tasks.json calls it too, so the commands live in exactly
# one place.
#
# Usage:
#   run.sh                          interactive menu
#   run.sh <target> [project]      direct
#   run.sh dev myproject           e.g. dev container for a project
#
# Targets:
#   dev|docs|review <project>   core profiles (need a project name)
#   sandbox                     isolated scratch container
#   hermes                      ephemeral Hermes chat (Ollama tier)
#   hermes_claude               ephemeral Hermes + Claude Code delegation
#   hermes_codex                ephemeral Hermes + Codex delegation
#   hermes_all                  ephemeral Hermes + Claude Code + Codex
#   dashboard                   persistent dashboard, Ollama only
#   dashboard_claude            persistent dashboard + Claude Code
#   dashboard_codex             persistent dashboard + Codex
#   dashboard_all               persistent dashboard + Claude Code + Codex
#   models                       list models Ollama has pulled (starts
#                               the container if it isn't running)
#   pull [model]                pull a model into the local Ollama
#                               (default: gemma4:e2b if no name given)
#   ollama_down                  stop the local Ollama container
#   docker_clean                 free disk: prune stopped containers,
#                               unused images, build cache, networks
# (asked PER CATEGORY,
#                               not one blanket y/N — no volumes exist
#                               in this project so none are at risk)
#   dashboard_auth               generate/print a dashboard basic_auth
#                               config block (terminal only — password
#                               entry isn't masked in VS Code tasks)
#   down                        stop whatever dashboard is running
#   ps                          show running workspace containers
#   health                      run scripts/health_check.sh
#   drift                       run bootstrap/setup.sh --verify
#   docker_status               which Docker backend this distro's
#                               CLI points at (Desktop shim vs native
#                               docker-ce) + migration prerequisites
#   docker_migrate              move the stack to native docker-ce
#                               (reversible; needs sudo + network)
#   docker_revert               back to the Docker Desktop backend
#                               (stops the native service, uninstalls
#                               nothing — see migrate_docker_backend.sh)
#   bootstrap                   re-run bootstrap/setup.sh (idempotent —
#                               "exists, skipping" on a healthy tree)
#   test                        run the bats regression suite
#                               (bootstrap/setup.bats)
#   check_all                   health + drift + test in sequence —
#                               the local stand-in for CI; stops at
#                               the first failure
#
# Flags:
#   -r | --remote-ollama   don't include ollama.yaml (config.yaml
#                          points at a remote Ollama, e.g. a desktop
#                          GPU over the LAN). Default is to include
#                          it — matches the current local-GPU setup.
#   --project=<name>       mount a real project (read-write, at
#                          /workspace) into ANY Hermes chat or
#                          dashboard profile — hermes, hermes_claude,
#                          hermes_codex, hermes_all, dashboard,
#                          dashboard_claude, dashboard_codex,
#                          dashboard_all. Delegation calls still need
#                          workdir=/workspace explicitly (Hermes's
#                          terminal tool doesn't reliably pick up the
#                          container's own default workdir) — see
#                          delegation_phrasing.md.
#                          e.g. run.sh --project=hydrogen-sky hermes_all
#                               run.sh --project=hydrogen-sky dashboard_all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(dirname "$SCRIPT_DIR")"
COMPOSE_DIR="$INFRA/compose"
ENV_FILE="../workspace.env"          # relative to COMPOSE_DIR, as documented
SECRETS_DIR="$HOME/.secrets"
PROJECTS_DIR="$(dirname "$INFRA")/projects"

[ -d "$COMPOSE_DIR" ] || { echo "compose/ not found at $COMPOSE_DIR — run setup.sh first."; exit 1; }

WITH_OLLAMA=1
HERMES_PROJECT=""
ARGS=()
for a in "$@"; do
  case "$a" in
    -r|--remote-ollama) WITH_OLLAMA=0 ;;
    --project=*) export HERMES_PROJECT="${a#--project=}" ;;
    -h|--help) sed -n '2,76p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

TARGET="${1:-}"
PROJECT_ARG="${2:-}"

if [ -n "$HERMES_PROJECT" ] && [ ! -d "$PROJECTS_DIR/$HERMES_PROJECT" ]; then
  echo "No such project dir: $PROJECTS_DIR/$HERMES_PROJECT"
  echo "Available projects:"
  ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
  exit 1
fi

compose() {
  # Always run from compose/, always with the manifest — the two
  # things everyone forgets when typing by hand.
  ( cd "$COMPOSE_DIR" && docker compose --env-file "$ENV_FILE" "$@" )
}

ensure_ollama() {
  # `docker compose run` starts ONLY the named service plus its
  # depends_on — and depends_on was deliberately REMOVED from every
  # Hermes profile (remote-Ollama support). So in local mode the
  # ollama service must be brought up explicitly first, or Hermes
  # launches with no backend (ctx --). Finding #2 test
  # run. Idempotent: if ollama is already up, this is a no-op.
  # Dashboards don't need the "start ollama" half — `up -d` on
  # merged files starts all services anyway — but DO still need
  # ensure_model below, called separately after their own `up -d`.
  if [ "$WITH_OLLAMA" = "1" ]; then
    compose -f ollama.yaml up -d ollama
    ensure_model
  fi
}

ensure_model() {
  # Added so "pick a profile, it just works" is actually
  # true end to end — no separate `run.sh pull` step needed first.
  # LOCAL MODE ONLY: the desktop's own models are a different
  # machine's concern, managed independently (already confirmed
  # populated — see local_models.md); nothing to pull there from
  # here. `ollama pull` on an already-current model is a fast local
  # layer check, not a re-download, so this is cheap even when the
  # model's already present. Best-effort: a pull failure here
  # shouldn't block the actual launch, which will surface its own
  # clearer error if something's genuinely wrong.
  if [ "$WITH_OLLAMA" = "1" ]; then
    compose -f ollama.yaml exec -T ollama ollama pull gemma4:e2b >/dev/null 2>&1 || true
  fi
}

ollama_flag() {
  # Hermes profiles pair with ollama.yaml so the "ollama" hostname
  # resolves — unless config.yaml points at a remote instance.
  if [ "$WITH_OLLAMA" = "1" ]; then echo "-f ollama.yaml"; else echo ""; fi
}

project_mount_args() {
  # Mounts a project into a Hermes profile at runtime via `docker
  # compose run`'s own -v/-w flags — deliberately NOT a compose YAML
  # fragment. hermes/hermes_claude/hermes_codex/hermes_all are four
  # DIFFERENTLY-NAMED services (that's how the profile matrix keeps
  # them separate), so a single fragment file can't merge a volume
  # into whichever one happens to be running. `run`'s own -v/-w
  # apply to whatever service name is actually invoked, no matter
  # which — so no new file is needed for this. Read-write, fixed
  # path (/workspace, matching dev.yaml's own convention) regardless
  # of project name, so delegation phrasing never has to change.
  [ -n "$HERMES_PROJECT" ] || return 0
  echo "-v ${PROJECTS_DIR}/${HERMES_PROJECT}:/workspace -w /workspace"
}

dashboard_project_flag() {
  # The dashboard equivalent of project_mount_args() — but dashboards
  # use `up -d`, which doesn't take run-time -v/-w overrides the way
  # `run` does, so this genuinely needs a compose fragment. UNLIKE
  # the ephemeral profiles, each dashboard variant has exactly ONE
  # service name per file — so a fragment CAN target it directly.
  # One fragment per dashboard, not one shared file: a shared file
  # listing all four dashboard service names would make compose
  # treat the OTHER three (not actually being launched) as new,
  # incomplete standalone services with no image/build — `up -d`
  # would then try to start those broken phantoms too. $1 is the
  # base service/file name, e.g. hermes_dashboard_with_all.
  [ -n "$HERMES_PROJECT" ] || { echo ""; return; }
  echo "-f ${1}_project.yaml"
}

need_project() {
  # dev/docs/review are parameterized by ${PROJECT}. Validate BEFORE
  # docker runs, with real error messages instead of compose's
  # variable-interpolation noise.
  local for_target="$1"
  if [ -z "$PROJECT_ARG" ]; then
    echo "Available projects:"
    ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
    read -r -p "Project name for '$for_target': " PROJECT_ARG
  fi
  [ -n "$PROJECT_ARG" ] || { echo "No project given."; exit 1; }
  [ -d "$PROJECTS_DIR/$PROJECT_ARG" ] \
    || { echo "No such project dir: $PROJECTS_DIR/$PROJECT_ARG"; exit 1; }
  if [ "$for_target" = "dev" ] && [ ! -f "$SECRETS_DIR/$PROJECT_ARG.env" ]; then
    echo "dev.yaml declares env_file \$SECRETS_DIR/$PROJECT_ARG.env and it doesn't exist."
    echo "Create it first (empty is fine):  touch $SECRETS_DIR/$PROJECT_ARG.env"
    exit 1
  fi
  export PROJECT="$PROJECT_ARG"
}

port_9119_owner() {
  docker ps --filter "publish=9119" --format '{{.Names}}' 2>/dev/null | head -1
}

guard_9119() {
  # hermes_dashboard.yaml and hermes_dashboard-with-*.yaml all claim
  # 127.0.0.1:9119 — only one can run. Detect and offer the swap
  # instead of letting docker fail with a bind error.
  local wanted="$1" owner; owner="$(port_9119_owner)"
  if [ -n "$owner" ] && [ "$owner" != "$wanted" ]; then
    echo "Port 9119 is held by: $owner"
    read -r -p "Stop it and start $wanted instead? [y/N] " yn
    case "$yn" in
      y|Y) docker stop "$owner" >/dev/null && echo "  stopped $owner" ;;
      *) echo "Leaving $owner running. Aborted."; exit 1 ;;
    esac
  fi
}

run_target() {
  if [ -n "$HERMES_PROJECT" ]; then
    case "$1" in
      hermes|hermes_claude|hermes_codex|hermes_all) : ;;             # supported (-v/-w)
      dashboard|dashboard_claude|dashboard_codex|dashboard_all) : ;; # supported (compose fragment)
      *)
        echo "--project=$HERMES_PROJECT has no effect on '$1' — only"
        echo "the Hermes chat/dashboard profiles support a project mount:"
        echo "hermes, hermes_claude, hermes_codex, hermes_all,"
        echo "dashboard, dashboard_claude, dashboard_codex, dashboard_all."
        exit 1
        ;;
    esac
  fi
  case "$1" in
    dev|docs|review)
      need_project "$1"
      compose -f "$1.yaml" run --rm "$1"
      ;;
    sandbox)
      compose -f sandbox.yaml run --rm sandbox
      ;;
    hermes)
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes.yaml run --rm $(project_mount_args) hermes
      ;;
    hermes_claude)
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_claude.yaml run --rm $(project_mount_args) hermes_claude
      ;;
    hermes_codex)
      # Confirmed working (features.md, "Supervisor
      # agent"). Two things to remember when delegating from inside
      # the session: (1) codex exec, not -p, and pty=true is
      # required; (2) wrap multi-command shell calls in
      # bash -c "cmd1 && cmd2" — Hermes's terminal tool errors
      # (exit 126) on a raw top-level && chain, unrelated to Codex.
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_codex.yaml run --rm $(project_mount_args) hermes_codex
      ;;
    hermes_all)
      # Confirmed working three interleaved delegation
      # calls in one continuous session (claude, codex, claude again)
      # all returned clean with no login prompt and no cross-provider
      # interference — the one risk individual per-provider testing
      # couldn't have caught.
      ensure_ollama
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_all.yaml run --rm $(project_mount_args) hermes_all
      ;;
    dashboard)
      guard_9119 "compose-hermes_dashboard-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard.yaml $(dashboard_project_flag hermes_dashboard) up -d
      ensure_model
      echo "Dashboard: http://127.0.0.1:9119"
      ;;
    dashboard_claude)
      guard_9119 "compose-hermes_dashboard_with_claude-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_claude.yaml $(dashboard_project_flag hermes_dashboard_with_claude) up -d
      ensure_model
      echo "Dashboard (with Claude Code delegation): http://127.0.0.1:9119"
      ;;
    dashboard_codex)
      # Confirmed working real delegation through the
      # persistent gateway returned CODEX DASHBOARD OK, no login
      # prompt. Same delegation recipe as hermes_codex (codex exec,
      # pty=true, bash -c wrapping for && chains — see that target's
      # comments above).
      guard_9119 "compose-hermes_dashboard_with_codex-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_codex.yaml $(dashboard_project_flag hermes_dashboard_with_codex) up -d
      ensure_model
      echo "Dashboard (with Codex delegation): http://127.0.0.1:9119"
      ;;
    dashboard_all)
      # Confirmed working three interleaved delegation
      # calls (claude, codex, claude again) through the persistent
      # gateway, reached remotely via the native Win11 app, all
      # returned clean with no login prompt and no cross-provider
      # interference. Both halves of the supervisor-agent idea —
      # ephemeral and dashboard, single-provider and combined — are
      # now proven end to end.
      guard_9119 "compose-hermes_dashboard_with_all-1"
      # shellcheck disable=SC2046
      compose $(ollama_flag) -f hermes_dashboard_with_all.yaml $(dashboard_project_flag hermes_dashboard_with_all) up -d
      ensure_model
      echo "Dashboard (with Claude Code + Codex delegation): http://127.0.0.1:9119"
      ;;
    down)
      local owner; owner="$(port_9119_owner)"
      if [ -n "$owner" ]; then
        docker stop "$owner" >/dev/null && echo "stopped: $owner"
      else
        echo "No dashboard holding port 9119."
      fi
      ;;
    ollama_down)
      if docker ps --format '{{.Names}}' | grep -qx compose-ollama-1; then
        docker stop compose-ollama-1 >/dev/null && echo "stopped: compose-ollama-1"
      else
        echo "Ollama isn't running."
      fi
      ;;
    docker_clean)
      # Destructive — confirmation required PER CATEGORY (
      # was one blanket y/N that took this project's own hermes/agent
      # images along with everything else on a single 'y'). Nothing
      # here touches volumes — this project uses only bind mounts,
      # confirmed zero Docker volumes throughout, so there's nothing
      # volume-related to offer either way. Rebuilding this project's
      # images afterward is a normal --no-cache rebuild, not a
      # disaster recovery — same as setting up on a fresh machine.
      # Matches the manual cleanup sequence already proven to work
      # well (session): container/image/builder/network
      # prune, run separately rather than one opaque `system prune -a`
      # so each step's effect is visible AND individually skippable.
      echo "Current Docker disk usage:"
      docker system df
      echo
      echo "Asked per category instead of one blanket"
      echo "y/N — a prior all-or-nothing prune took project images"
      echo "along with everything else on a plain 'y'. Bind mounts"
      echo "only in this project — no volumes exist, so nothing"
      echo "volume-related is at risk either way; volumes aren't"
      echo "offered below because there's never anything to prune."
      echo
      read -r -p "  Remove stopped containers? [y/N] " dc_containers
      echo "  (includes THIS project's own hermes/agent images if not"
      echo "   currently running — they rebuild on next launch, just slower)"
      read -r -p "  Remove unused images? [y/N] " dc_images
      echo "  (frees the most space; next build of anything starts from scratch)"
      read -r -p "  Remove ALL build cache? [y/N] " dc_builder
      read -r -p "  Remove unused networks? [y/N] " dc_networks
      echo
      did_something=0
      case "$dc_containers" in
        y|Y) docker container prune -f; did_something=1 ;;
        *) echo "  skipped: containers" ;;
      esac
      case "$dc_images" in
        y|Y) docker image prune -a -f; did_something=1 ;;
        *) echo "  skipped: images" ;;
      esac
      case "$dc_builder" in
        y|Y) docker builder prune -a -f; did_something=1 ;;
        *) echo "  skipped: build cache" ;;
      esac
      case "$dc_networks" in
        y|Y) docker network prune -f; did_something=1 ;;
        *) echo "  skipped: networks" ;;
      esac
      echo
      if [ "$did_something" -eq 1 ]; then
        echo "Docker disk usage after cleanup:"
        docker system df
        echo
        echo "That frees space INSIDE Docker's WSL2 allocation only."
        echo "To reclaim it on the Windows side too, from an admin"
        echo "PowerShell:"
        echo "  wsl --shutdown"
        echo "  Optimize-VHD -Path <path-to-docker-desktop-data.vhdx> -Mode Full"
        echo "(or Docker Desktop -> Settings -> Resources -> Clean / Purge data)"
      else
        echo "Nothing selected — nothing removed."
      fi
      ;;
    dashboard_auth)
      # Confirmed necessary any dashboard profile refuses
      # to bind (Hermes's OWN internal auth gate, independent of
      # Docker's 127.0.0.1-only port mapping) until basic_auth is
      # configured in hermes-home/config.yaml — this doesn't survive
      # a hermes-home wipe (--secrets-only or a manual rm), so it
      # needs redoing after one. Prints the config block rather than
      # editing config.yaml directly — safer than blindly patching
      # hand-maintained YAML (risk of duplicate keys / clobbering an
      # existing block).
      local da_user da_pass da_hash
      read -r -p "Dashboard username: " da_user
      read -r -s -p "Dashboard password: " da_pass; echo
      [ -n "$da_user" ] && [ -n "$da_pass" ] || { echo "Both required."; exit 1; }
      # Password goes through an env var into the container, not
      # spliced into the python source string — avoids shell/python
      # quoting issues if the password contains quotes, $, etc.
      da_hash="$(compose -f hermes.yaml run --rm -e DA_PASS="$da_pass" hermes         python -c "import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ['DA_PASS']))"         2>/dev/null | tail -1)"
      if [ -z "$da_hash" ]; then
        echo "Hash generation failed — is the hermes image built? (run.sh hermes once first)"
        exit 1
      fi
      echo
      echo "Add this to ~/.secrets/hermes-home/config.yaml (create the"
      echo "dashboard: block if none exists yet; merge by hand if one does):"
      echo
      echo "  dashboard:"
      echo "    basic_auth:"
      echo "      username: $da_user"
      echo "      password_hash: \"$da_hash\""
      echo
      echo "Then restart whichever dashboard container is running so it"
      echo "re-reads config.yaml fresh, e.g.:"
      echo "  docker restart compose-hermes_dashboard-1"
      echo "  (or _with_claude-1 / _with_codex-1 / _with_all-1 — whichever's up)"
      ;;
    models)
      # Independent of any Hermes profile — just needs the ollama
      # service itself. up -d is a no-op if it's already running.
      compose -f ollama.yaml up -d ollama >/dev/null
      docker exec compose-ollama-1 ollama list
      ;;
    pull)
      local model="${PROJECT_ARG:-gemma4:e2b}"
      compose -f ollama.yaml up -d ollama >/dev/null
      echo "Pulling $model ..."
      docker exec compose-ollama-1 ollama pull "$model"
      ;;
    ps)
      docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
      ;;
    health)
      bash "$INFRA/scripts/health_check.sh"
      ;;
    drift)
      [ -f "$INFRA/bootstrap/setup.sh" ] \
        || { echo "setup.sh not found at $INFRA/bootstrap/ — run drift check from wherever it lives."; exit 1; }
      bash "$INFRA/bootstrap/setup.sh" --verify
      ;;
    docker_status)
      bash "$INFRA/scripts/migrate_docker_backend.sh" --check
      ;;
    docker_migrate)
      # Gated in features.md until the current test pass is finished.
      bash "$INFRA/scripts/migrate_docker_backend.sh" --migrate
      ;;
    docker_revert)
      bash "$INFRA/scripts/migrate_docker_backend.sh" --revert
      ;;
    bootstrap)
      # Safe as a one-click task BECAUSE setup.sh is idempotent —
      # on a healthy tree this is a wall of "exists, skipping".
      [ -f "$INFRA/bootstrap/setup.sh" ] \
        || { echo "setup.sh not found at $INFRA/bootstrap/."; exit 1; }
      bash "$INFRA/bootstrap/setup.sh"
      ;;
    test)
      [ -f "$INFRA/bootstrap/setup.bats" ] \
        || { echo "setup.bats not found at $INFRA/bootstrap/."; exit 1; }
      command -v bats >/dev/null 2>&1 \
        || { echo "bats not installed — sudo apt install bats (see setup.bats header)."; exit 1; }
      ( cd "$INFRA/bootstrap" && bats setup.bats )
      ;;
    check_all)
      # The full local confidence sweep, one click: does the live
      # tree look right (health), does it match what's embedded
      # (drift), does the script logic still hold (test). set -e
      # stops the chain at the first failure.
      run_target health
      run_target drift
      run_target test
      echo
      echo "== check_all: health + drift + test all passed =="
      ;;
    *)
      echo "Unknown target: $1 (see run.sh --help)"; exit 1 ;;
  esac
}

if [ -n "$TARGET" ]; then
  run_target "$TARGET"
  exit 0
fi

echo "What do you want to run? (Ctrl-C to quit)"
PS3="> "
select choice in \
  "hermes           — ephemeral chat, Ollama tier" \
  "hermes_claude    — ephemeral chat + Claude Code delegation" \
  "hermes_codex     — ephemeral chat + Codex delegation" \
  "hermes_all       — ephemeral chat + Claude Code + Codex" \
  "dashboard        — persistent dashboard, Ollama only" \
  "dashboard_claude — persistent dashboard + Claude Code" \
  "dashboard_codex  — persistent dashboard + Codex" \
  "dashboard_all    — persistent dashboard + Claude Code + Codex" \
  "dev              — dev container for a project" \
  "docs / review / sandbox" \
  "dashboard_auth   — generate a dashboard password (run from a terminal)" \
  "down             — stop the running dashboard" \
  "ollama_down      — stop the local Ollama container" \
  "models           — list pulled Ollama models" \
  "pull             — pull an Ollama model (default gemma4:e2b)" \
  "docker_clean     — free disk (prune containers/images/cache/networks)" \
  "ps / health / drift" \
  "docker backend      — status / migrate / revert (Desktop <-> native)" \
  "bootstrap / test / check_all — setup.sh, bats suite, or all checks" \
  "hermes/dashboard with a project mounted (--project=<name>)"; do
  case "$REPLY" in
    1) run_target hermes; break ;;
    2) run_target hermes_claude; break ;;
    3) run_target hermes_codex; break ;;
    4) run_target hermes_all; break ;;
    5) run_target dashboard; break ;;
    6) run_target dashboard_claude; break ;;
    7) run_target dashboard_codex; break ;;
    8) run_target dashboard_all; break ;;
    9) run_target dev; break ;;
    10) read -r -p "which (docs/review/sandbox): " t; run_target "$t"; break ;;
    11) run_target dashboard_auth; break ;;
    12) run_target down; break ;;
    13) run_target ollama_down; break ;;
    14) run_target models; break ;;
    15) read -r -p "model to pull (blank = gemma4:e2b): " m; PROJECT_ARG="$m" run_target pull; break ;;
    16) run_target docker_clean; break ;;
    17) read -r -p "which (ps/health/drift): " t; run_target "$t"; break ;;
    18) read -r -p "which (docker_status/docker_migrate/docker_revert): " t; run_target "$t"; break ;;
    19) read -r -p "which (bootstrap/test/check_all): " t; run_target "$t"; break ;;
    20)
      read -r -p "project name (blank = none): " p
      if [ -n "$p" ]; then
        if [ ! -d "$PROJECTS_DIR/$p" ]; then
          echo "No such project dir: $PROJECTS_DIR/$p"
          echo "Available projects:"
          ls -1 "$PROJECTS_DIR" 2>/dev/null | sed 's/^/  /' || true
          break
        fi
        export HERMES_PROJECT="$p"
      fi
      read -r -p "which (hermes/hermes_claude/hermes_codex/hermes_all/dashboard/dashboard_claude/dashboard_codex/dashboard_all): " t
      run_target "$t"
      break
      ;;
    *) echo "1-20 please" ;;
  esac
done
