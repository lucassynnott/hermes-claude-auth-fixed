#!/usr/bin/env bash
set -euo pipefail

# One-line installer for the private fixed hermes-claude-auth copy.
# Requires GitHub credentials with access to lucassynnott/hermes-claude-auth-fixed.

REPO="${HERMES_CLAUDE_AUTH_REPO:-https://github.com/lucassynnott/hermes-claude-auth-fixed.git}"
TMPDIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

git clone --depth 1 "$REPO" "$TMPDIR" 2>/dev/null
bash "$TMPDIR/install.sh"
