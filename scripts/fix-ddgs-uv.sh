#!/usr/bin/env bash
# fix-ddgs-uv.sh
# Patches hermes_*/Dockerfile to install uv before the ddgs build step,
# which breaks whenever nousresearch/hermes-agent:latest stops shipping
# uv on PATH. Idempotent — safe to re-run.
#
# Usage: bash fix-ddgs-uv.sh [infra-root]
#   infra-root defaults to ~/workspace/infrastructure
#
# Run it:
# cd ~/workspace/infrastructure/scripts
# bash fix-ddgs-uv.sh

set -euo pipefail

INFRA_ROOT="${1:-$HOME/workspace/infrastructure}"
MARKER="astral.sh/uv/install.sh"

mapfile -t files < <(grep -rl "ddgs" "$INFRA_ROOT/docker" --include=Dockerfile* 2>/dev/null || true)
[ "${#files[@]}" -gt 0 ] || { echo "No Dockerfiles with a ddgs step found."; exit 1; }

fail=0
for file in "${files[@]}"; do
    if grep -qF "$MARKER" "$file"; then
        echo "SKIP  $file (already present)"
        continue
    fi

    tmp="$(mktemp)"
    awk '
        /RUN uv pip install --python .*ddgs/ && !inserted {
            print "RUN curl -LsSf https://astral.sh/uv/install.sh | sh \\"
            print "    && mv /root/.local/bin/uv /usr/local/bin/uv"
            print ""
            inserted = 1
        }
        { print }
    ' "$file" > "$tmp"

    if grep -qF "$MARKER" "$tmp"; then
        mv "$tmp" "$file"
        echo "FIXED $file"
    else
        rm -f "$tmp"
        echo "FAILED $file — did not match, check manually: grep -n ddgs \"$file\" | cat -A"
        fail=1
    fi
done

[ "$fail" -eq 0 ] && echo "All confirmed fixed." || { echo "Some files still need manual edits."; exit 1; }