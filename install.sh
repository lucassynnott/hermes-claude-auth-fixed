#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
PATCHES_DIR="$HERMES_HOME/patches"
MARKER="# hermes-claude-auth managed"
BOOTSTRAP_NAME="_hermes_claude_auth_bootstrap.py"
PTH_NAME="hermes_claude_auth.pth"

POST_UPDATE=false
CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --post-update) POST_UPDATE=true ;;
        --check)       CHECK_ONLY=true ;;
        *) ;;
    esac
done

if [ ! -d "$HERMES_AGENT_DIR" ]; then
    printf "${RED}[✗] hermes-agent not found at %s${RESET}\n" "$HERMES_AGENT_DIR"
    printf "    Install hermes-agent first: https://github.com/nousresearch/hermes-agent\n"
    exit 1
fi

resolve_python() {
    local dir="$1"
    if [ -x "$dir/bin/python" ]; then
        echo "$dir/bin/python"
    elif [ -x "$dir/bin/python3" ]; then
        echo "$dir/bin/python3"
    fi
}

can_import_hermes_agent() {
    "$1" -c "import agent.anthropic_adapter" >/dev/null 2>&1
}

site_packages_for() {
    "$1" -c "import site; print(site.getsitepackages()[0] if site.getsitepackages() else site.getusersitepackages())" 2>/dev/null
}

install_hook_into() {
    local py="$1"
    local site_packages bootstrap_path pth_path sitecustomize legacy_backup
    site_packages="$(site_packages_for "$py")" || return 1
    if [ -z "$site_packages" ] || [ ! -d "$site_packages" ]; then
        return 1
    fi

    bootstrap_path="$site_packages/$BOOTSTRAP_NAME"
    pth_path="$site_packages/$PTH_NAME"
    sitecustomize="$site_packages/sitecustomize.py"
    legacy_backup="$sitecustomize.pre-hermes-claude-auth"

    cp "$SCRIPT_DIR/$BOOTSTRAP_NAME" "$bootstrap_path"
    chmod 644 "$bootstrap_path"
    cp "$SCRIPT_DIR/$PTH_NAME" "$pth_path"
    chmod 644 "$pth_path"

    if [ -f "$sitecustomize" ] && grep -q "$MARKER" "$sitecustomize"; then
        if [ -f "$legacy_backup" ]; then
            mv "$legacy_backup" "$sitecustomize"
            printf "${YELLOW}[~] Migrated legacy sitecustomize.py install for %s — restored original backup${RESET}\n" "$py"
        else
            rm -f "$sitecustomize"
            printf "${YELLOW}[~] Migrated legacy sitecustomize.py install for %s — removed superseded hook${RESET}\n" "$py"
        fi
    fi

    find "$site_packages" \
        -maxdepth 3 \
        \( -name '_hermes_claude_auth_bootstrap*.pyc' -o -name 'sitecustomize*.pyc' \) \
        -delete 2>/dev/null || true

    printf "${GREEN}[✓] Installed .pth hook into %s${RESET}\n" "$site_packages"
}

candidate_pythons() {
    local py venv_subdir found
    declare -A seen=()

    if [ -n "${HERMES_PYTHON:-}" ] && [ -x "$HERMES_PYTHON" ]; then
        printf '%s\n' "$HERMES_PYTHON"
        seen["$HERMES_PYTHON"]=1
    fi

    if [ -n "${HERMES_VENV:-}" ] && [ -d "$HERMES_VENV" ]; then
        py="$(resolve_python "$HERMES_VENV")"
        if [ -n "$py" ] && [ -z "${seen[$py]:-}" ]; then printf '%s\n' "$py"; seen["$py"]=1; fi
    fi

    for venv_subdir in venv .venv; do
        if [ -d "$HERMES_AGENT_DIR/$venv_subdir" ]; then
            py="$(resolve_python "$HERMES_AGENT_DIR/$venv_subdir")"
            if [ -n "$py" ] && [ -z "${seen[$py]:-}" ]; then printf '%s\n' "$py"; seen["$py"]=1; fi
        fi
    done

    if command -v hermes >/dev/null 2>&1; then
        found="$(command -v hermes)"
        if head -n 1 "$found" 2>/dev/null | grep -q '^#!'; then
            py="$(head -n 1 "$found" | sed 's/^#!//')"
            if [ -x "$py" ] && [ -z "${seen[$py]:-}" ]; then printf '%s\n' "$py"; seen["$py"]=1; fi
        fi
    fi

    while IFS= read -r py; do
        [ -x "$py" ] || continue
        if [ -z "${seen[$py]:-}" ]; then printf '%s\n' "$py"; seen["$py"]=1; fi
    done < <(compgen -c python3 2>/dev/null | while read -r cmd; do command -v "$cmd"; done | sort -u)
}

mapfile -t CANDIDATES < <(candidate_pythons)
INSTALL_TARGETS=()
for py in "${CANDIDATES[@]}"; do
    if can_import_hermes_agent "$py"; then
        INSTALL_TARGETS+=("$py")
    fi
done

if [ "${#INSTALL_TARGETS[@]}" -eq 0 ]; then
    printf "${RED}[✗] No Python interpreter found that can import agent.anthropic_adapter${RESET}\n"
    printf "    Set HERMES_VENV or HERMES_PYTHON to the Hermes interpreter and retry.\n"
    exit 1
fi

PRIMARY_PYTHON="${INSTALL_TARGETS[0]}"
PRIMARY_SITE_PACKAGES="$(site_packages_for "$PRIMARY_PYTHON")"
BOOTSTRAP_PATH="$PRIMARY_SITE_PACKAGES/$BOOTSTRAP_NAME"
PTH_PATH="$PRIMARY_SITE_PACKAGES/$PTH_NAME"

if $CHECK_ONLY; then
    ALL_OK=true
    if [[ -f "$PATCHES_DIR/anthropic_billing_bypass.py" ]]; then
        printf "${GREEN}[✓] %s${RESET}\n" "$PATCHES_DIR/anthropic_billing_bypass.py"
    else
        printf "${RED}[✗] MISSING: %s${RESET}\n" "$PATCHES_DIR/anthropic_billing_bypass.py"
        ALL_OK=false
    fi

    for py in "${INSTALL_TARGETS[@]}"; do
        site_packages="$(site_packages_for "$py")"
        if [[ -f "$site_packages/$BOOTSTRAP_NAME" ]] && grep -q "$MARKER" "$site_packages/$BOOTSTRAP_NAME"; then
            printf "${GREEN}[✓] bootstrap module present for %s${RESET}\n" "$py"
        else
            printf "${RED}[✗] bootstrap module missing for %s${RESET}\n" "$py"
            ALL_OK=false
        fi
        if [[ -f "$site_packages/$PTH_NAME" ]] && grep -q "import _hermes_claude_auth_bootstrap" "$site_packages/$PTH_NAME"; then
            printf "${GREEN}[✓] .pth shim present for %s${RESET}\n" "$py"
        else
            printf "${RED}[✗] .pth shim missing for %s${RESET}\n" "$py"
            ALL_OK=false
        fi
    done

    POST_MERGE_HOOK="$HERMES_AGENT_DIR/.git/hooks/post-merge"
    if [[ -f "$POST_MERGE_HOOK" && -x "$POST_MERGE_HOOK" ]] \
        && grep -q "Recovering Claude Code bypass" "$POST_MERGE_HOOK" 2>/dev/null; then
        printf "${GREEN}[✓] auto-recovery hook present${RESET}\n"
    elif [[ -d "$HERMES_AGENT_DIR/.git/hooks" ]]; then
        printf "${RED}[✗] auto-recovery hook MISSING, stale, or not executable${RESET}\n"
        ALL_OK=false
    else
        printf "${YELLOW}[!] hermes-agent git hooks directory not found; auto-recovery hook not checked${RESET}\n"
    fi

    INSTALLED_PATCH="$PATCHES_DIR/anthropic_billing_bypass.py"
    REPO_PATCH="$SCRIPT_DIR/anthropic_billing_bypass.py"
    if [[ -f "$INSTALLED_PATCH" && -f "$REPO_PATCH" ]] && ! cmp -s "$INSTALLED_PATCH" "$REPO_PATCH"; then
        printf "${YELLOW}[!] DRIFT: anthropic_billing_bypass.py differs from repo (%s)${RESET}\n" "$REPO_PATCH"
        ALL_OK=false
    fi

    if $ALL_OK; then
        printf "\n${GREEN}Claude Code bypass patches intact.${RESET}\n"
        exit 0
    fi
    printf "\n${YELLOW}Patches missing or drifted. To restore from repo: ./install.sh${RESET}\n"
    printf "${YELLOW}If the installed copy is the newer one, sync it back to the repo and commit instead.${RESET}\n"
    exit 1
fi

if $POST_UPDATE; then
    printf "${YELLOW}[post-update] Restoring Claude Code bypass after hermes update...${RESET}\n"
else
    printf "${YELLOW}[install] Installing Claude Code OAuth bypass...${RESET}\n"
fi

mkdir -p "$PATCHES_DIR"
cp "$SCRIPT_DIR/anthropic_billing_bypass.py" "$PATCHES_DIR/anthropic_billing_bypass.py"
chmod 644 "$PATCHES_DIR/anthropic_billing_bypass.py"
printf "${GREEN}[✓] Copied patch to %s/${RESET}\n" "$PATCHES_DIR"
rm -rf "$PATCHES_DIR/__pycache__" 2>/dev/null || true

for py in "${INSTALL_TARGETS[@]}"; do
    install_hook_into "$py"
done

PATCH_CHECK=$("$PRIMARY_PYTHON" -c "
import sys, os
sys.path.insert(0, os.path.expanduser('$PATCHES_DIR'))
try:
    import anthropic_billing_bypass
    v = getattr(anthropic_billing_bypass, '__version__', 'unknown')
    print(f'OK (v{v})')
except Exception as e:
    print(f'FAIL ({e})')
" 2>/dev/null || echo "FAIL (import error)")
printf "${GREEN}[✓] Patch integrity: %s${RESET}\n" "$PATCH_CHECK"

GIT_HOOKS_DIR="$HERMES_AGENT_DIR/.git/hooks"
POST_MERGE_HOOK="$GIT_HOOKS_DIR/post-merge"
ANTIGRAVITY_HOOK="$SCRIPT_DIR/../hermes-google-antigravity-plugin/scripts/post-merge-hook.sh"
if [ -f "$ANTIGRAVITY_HOOK" ]; then
    HOOK_SRC="$ANTIGRAVITY_HOOK"
elif [ -f "$SCRIPT_DIR/post-merge-hook.sh" ]; then
    HOOK_SRC="$SCRIPT_DIR/post-merge-hook.sh"
else
    HOOK_SRC=""
fi
if [ -d "$GIT_HOOKS_DIR" ] && [ -n "$HOOK_SRC" ] && [ -f "$HOOK_SRC" ]; then
    cp "$HOOK_SRC" "$POST_MERGE_HOOK"
    chmod +x "$POST_MERGE_HOOK"
    printf "${GREEN}[✓] Installed auto-recovery hook (post-merge)${RESET}\n"
fi

if [ "$(uname -s)" = "Darwin" ]; then
    CRED_FILE="$HOME/.claude/.credentials.json"
    if KEYCHAIN_CRED="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)"; then
        mkdir -p "$(dirname "$CRED_FILE")"
        if [ ! -f "$CRED_FILE" ] || [ "$(cat "$CRED_FILE" 2>/dev/null)" != "$KEYCHAIN_CRED" ]; then
            printf '%s' "$KEYCHAIN_CRED" > "$CRED_FILE"
            chmod 600 "$CRED_FILE"
            printf "${GREEN}[✓] Mirrored Claude Code credentials from Keychain → %s${RESET}\n" "$CRED_FILE"
        else
            printf "${GREEN}[✓] Claude Code credentials file already matches Keychain${RESET}\n"
        fi
    elif [ ! -f "$CRED_FILE" ]; then
        printf "${YELLOW}[!] macOS detected but no 'Claude Code-credentials' Keychain entry found${RESET}\n"
        printf "    Run: claude auth login --claudeai\n"
    fi
fi

if systemctl --user is-active hermes-gateway.service >/dev/null 2>&1; then
    systemctl --user restart hermes-gateway.service
    printf "${GREEN}[✓] Restarted hermes-gateway.service${RESET}\n"
else
    printf "${YELLOW}[!] hermes-gateway not running — restart manually when ready${RESET}\n"
fi

printf "\n"
if $POST_UPDATE; then
    printf "${GREEN}Post-update recovery complete.${RESET}\n"
    printf "\nVerify: hermes chat --provider anthropic -m claude-sonnet-4-6 -q 'test'\n"
else
    printf "${GREEN}Installation complete.${RESET}\n"
    printf "\n  Patch:     %s/anthropic_billing_bypass.py\n" "$PATCHES_DIR"
    printf "  Interpreters patched:\n"
    for py in "${INSTALL_TARGETS[@]}"; do
        printf "    - %s\n" "$py"
    done
fi
