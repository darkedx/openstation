#!/usr/bin/env bash

set -e

# Self-demote to dev user if running as root
if [ "$(id -u)" -eq 0 ]; then
    # echo ">> Detected running as root. Switching to dev user..."
    exec sudo -i -u dev AUTO_INSTALL="$AUTO_INSTALL" bash "$0" "$@"
fi

# Ensure mise and local bin are loaded
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

# Helper to check AUTO_INSTALL
should_update() {
    local tool="$1"
    local tools
    if [ -z "$AUTO_INSTALL" ]; then
        return 1
    fi
    tools=$(echo "$AUTO_INSTALL" | tr '[:upper:]' '[:lower:]')
    if [[ ",${tools}," == *",${tool},"* ]]; then
        return 0
    else
        return 1
    fi
}

echo ">> [$(date)] Running AI Tools Update Check..."

if should_update "gemini"; then
    echo ">> Checking updates for Gemini CLI..."
    GEMINI_LATEST=$(npm view @google/gemini-cli version 2>/dev/null)
    GEMINI_INSTALLED=""
    if command -v gemini >/dev/null 2>&1; then
        GEMINI_INSTALLED=$(gemini --version 2>/dev/null)
    fi

    if [ -n "$GEMINI_LATEST" ]; then
        if [ "$GEMINI_INSTALLED" != "$GEMINI_LATEST" ]; then
            echo ">> Upgrading Gemini CLI (Current: ${GEMINI_INSTALLED:-None} -> Latest: $GEMINI_LATEST)..."
            npm install -g @google/gemini-cli@latest
            mise reshim
        else
            echo ">> Gemini CLI is already up to date ($GEMINI_INSTALLED)."
        fi
    else
        echo "Warning: Could not fetch latest Gemini CLI version. Attempting update anyway..."
        npm install -g @google/gemini-cli@latest
        mise reshim
    fi
fi

if should_update "claude"; then
    echo ">> Checking updates for Claude Code..."
    # Dynamically fetch the GCS bucket URL from the install script to find the latest version
    GCS_BUCKET=$(curl -fsSL https://claude.ai/install.sh | grep 'GCS_BUCKET="' | cut -d'"' -f2)
    
    if [ -n "$GCS_BUCKET" ]; then
        CLAUDE_LATEST=$(curl -fsSL "$GCS_BUCKET/latest")
    else
        CLAUDE_LATEST=""
    fi
    
    if [ -z "$CLAUDE_LATEST" ]; then
        echo "Warning: Could not fetch latest Claude Code version. Skipping update check."
    else
        CLAUDE_INSTALLED=""
        if command -v claude >/dev/null 2>&1; then
            CLAUDE_INSTALLED=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        fi

        if [ "$CLAUDE_INSTALLED" != "$CLAUDE_LATEST" ]; then
            echo ">> Upgrading Claude Code (Current: ${CLAUDE_INSTALLED:-None} -> Latest: $CLAUDE_LATEST)..."
            curl -fsSL https://claude.ai/install.sh | bash
            mise reshim
        else
            echo ">> Claude Code is already up to date ($CLAUDE_INSTALLED)."
        fi
    fi
fi

echo ">> AI Tools Update Completed."
