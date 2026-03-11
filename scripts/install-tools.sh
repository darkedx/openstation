#!/usr/bin/env bash

set -e

# Self-demote to dev user if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo ">> Detected running as root. Switching to dev user..."
    # Use sudo -i to ensure we get the user's environment.
    # We must explicitly pass AUTO_INSTALL and preserve the script path ($0)
    # Using bash explicitly to run the script
    exec sudo -i -u dev AUTO_INSTALL="$AUTO_INSTALL" bash "$0" "$@"
fi

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Running as dev user
USER_HOME="$HOME"
BASHRC_FILE="$HOME/.bashrc"
cd "$USER_HOME"
# <HELPERS>
should_install() {
    local tool="$1"
    local tools
    if [ -z "$AUTO_INSTALL" ]; then
        return 1
    fi
    tools=$(echo "$AUTO_INSTALL" | tr '[:upper:]' '[:lower:]')
    # Add surrounding commas to handle edge cases
    if [[ ",${tools}," == *",${tool},"* ]]; then
        return 0
    else
        return 1
    fi
}

update_apt_cache() {
    # Simple lock mechanism for apt update
    if [ -z "$APT_UPDATED" ]; then
        echo ">> Updating APT cache..."
        # Wait for lock
        while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            echo "Waiting for apt lock..."
            sleep 1
        done
        sudo apt-get update
        export APT_UPDATED=true
    fi
}
# </HELPERS>

# <MISE>
configure_mise() {
    # .bashrc should already have mise activation from Dockerfile
    
    if ! grep -Fq 'eval "$(mise activate bash)"' "$BASHRC_FILE"; then
        echo ">> Adding mise activation to .bashrc"
        echo 'eval "$(mise activate bash)"' >> "$BASHRC_FILE"
    fi
    
    # Ensure $HOME/.local/bin is in PATH in .bashrc
    if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$BASHRC_FILE"; then
        echo ">> Adding $HOME/.local/bin to PATH in .bashrc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$BASHRC_FILE"
    fi
    
    # Ensure mise and local bin are in PATH for this script execution
    export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

    if command -v mise >/dev/null 2>&1; then

        echo ">> Installing/Upgrading mise tools..."
        mise install --yes && mise upgrade --yes

        if should_install "gemini"; then
            echo ">> Checking Gemini CLI..."
            GEMINI_LATEST=$(npm view @google/gemini-cli version 2>/dev/null)
            GEMINI_INSTALLED=""
            if command -v gemini >/dev/null 2>&1; then
                GEMINI_INSTALLED=$(gemini --version 2>/dev/null)
            fi

            if [ -n "$GEMINI_LATEST" ]; then
                if [ "$GEMINI_INSTALLED" != "$GEMINI_LATEST" ]; then
                    echo ">> Installing/Upgrading Gemini CLI (Current: ${GEMINI_INSTALLED:-None}, Latest: $GEMINI_LATEST)..."
                    npm install -g @google/gemini-cli@latest
                    mise reshim
                else
                    echo ">> Gemini CLI is already up to date ($GEMINI_INSTALLED)."
                fi
            else
                 echo "Warning: Could not fetch latest Gemini CLI version. Attempting installation anyway..."
                 npm install -g @google/gemini-cli@latest
                 mise reshim
            fi
        fi
        if should_install "claude"; then
            echo ">> Checking Claude Code installation..."
            # Dynamically fetch the GCS bucket URL from the install script to find the latest version
            GCS_BUCKET=$(curl -fsSL https://claude.ai/install.sh | grep 'GCS_BUCKET="' | cut -d'"' -f2)
            
            if [ -n "$GCS_BUCKET" ]; then
                CLAUDE_LATEST=$(curl -fsSL "$GCS_BUCKET/latest")
            else
                CLAUDE_LATEST=""
            fi
            
            if [ -z "$CLAUDE_LATEST" ]; then
                echo "Warning: Could not fetch latest Claude Code version. Attempting installation anyway..."
                curl -fsSL https://claude.ai/install.sh | bash
                mise reshim
            else
                CLAUDE_INSTALLED=""
                if command -v claude >/dev/null 2>&1; then
                    CLAUDE_INSTALLED=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
                fi
                
                if [ "$CLAUDE_INSTALLED" != "$CLAUDE_LATEST" ]; then
                    echo ">> Installing/Upgrading Claude Code (Current: ${CLAUDE_INSTALLED:-None}, Latest: $CLAUDE_LATEST)..."
                    curl -fsSL https://claude.ai/install.sh | bash
                    mise reshim
                else
                    echo ">> Claude Code is already up to date ($CLAUDE_INSTALLED)."
                fi

                # Post-install configuration for Claude
                if [ ! -f "$HOME/.claude.json" ]; then
                    echo ">> Configuring initial Claude settings..."
                    if [ -f "/usr/local/share/claude-default.json" ]; then
                        # Use GNU date for milliseconds
                        CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
                        # Use jq to update the firstStartTime
                        jq --arg time "$CURRENT_TIME" '.firstStartTime = $time' "/usr/local/share/claude-default.json" > "$HOME/.claude.json"
                        echo ">> Created ~/.claude.json with firstStartTime=$CURRENT_TIME"
                    else
                        echo "Warning: Default Claude config not found at /usr/local/share/claude-default.json"
                    fi
                fi
            fi
        fi
        # Post-install hooks
        if should_install "gemini"; then
            echo ">> Configuring Gemini CLI..."
            GEMINI_BIN=$(command -v gemini || true)
            if [ -z "$GEMINI_BIN" ]; then
                echo "Warning: Gemini CLI executable not found."
            fi
        fi
    else
        echo ">> mise not found, skipping mise tools installation."
    fi
}
# </MISE>

# <ANTIGRAVITY>
install_antigravity() {
    if should_install "antigravity"; then
        echo ">> Checking Antigravity..."
        
        local update_script=""
        # Prioritize using the script in the same directory (dev environment/local run)
        if [ -f "$SCRIPT_DIR/update_antigravity.sh" ]; then
            update_script="$SCRIPT_DIR/update_antigravity.sh"
        # Then check common locations in Docker container
        elif [ -f "/update_antigravity.sh" ]; then
            update_script="/update_antigravity.sh"
        fi
        
        if [ -n "$update_script" ]; then
            echo ">> Running Antigravity installer: $update_script"
            sudo chmod +x "$update_script"
            sudo DEV_HOME="$HOME" "$update_script"
            
            # Configure auto-update every 12 hours
            echo ">> Configuring Antigravity auto-update (every 12 hours)..."
            if [ "$(realpath "$update_script")" != "/usr/local/bin/update_antigravity.sh" ]; then
                sudo cp "$update_script" /usr/local/bin/update_antigravity.sh
            fi
            sudo chmod +x /usr/local/bin/update_antigravity.sh
            
            # Add crontab task
            local CRON_FILE="/etc/cron.d/antigravity-update"
            echo "0 */12 * * * root DEV_HOME=\"$HOME\" /usr/local/bin/update_antigravity.sh >> /var/log/cron.log 2>&1" | sudo tee "$CRON_FILE" > /dev/null
            sudo chmod 0644 "$CRON_FILE"
            echo ">> Antigravity auto-update task added to $CRON_FILE"
        else
            echo "Error: update_antigravity.sh not found. Cannot install Antigravity."
        fi
    fi

    # Create symlink for antigravity if it exists
    if [ -f "/usr/bin/antigravity" ] && [ ! -e "/usr/local/bin/agy" ]; then
        echo ">> Creating antigravity symlink: agy"
        sudo ln -s /usr/bin/antigravity /usr/local/bin/agy
    fi
}
# </ANTIGRAVITY>

# <FVM>
get_fvm_latest_version() {
    curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/leoafarias/fvm/releases/latest" 2>/dev/null | \
        grep -o '"tag_name": *"[^"]*"' | \
        head -n 1 | \
        sed -E 's/.*"v?([^"]+)".*/\1/'
}

get_fvm_installed_version() {
    local fvm_bin="$HOME/fvm/bin/fvm"
    
    if [ -x "$fvm_bin" ]; then
        "$fvm_bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

install_fvm() {
    if should_install "fvm"; then
        echo ">> Checking FVM..."
        
        local installed_version
        local latest_version
        installed_version=$(get_fvm_installed_version)
        latest_version=$(get_fvm_latest_version)
        
        if [ -n "$installed_version" ]; then
            if [ -z "$latest_version" ]; then
                echo ">> FVM installed version: $installed_version, cannot get latest version, skipping update"
                return
            fi
            if [ "$installed_version" = "$latest_version" ]; then
                echo ">> FVM is already the latest version: $installed_version, skipping installation"
                if ! grep -q 'export PATH="$HOME/fvm/bin:$PATH"' "$BASHRC_FILE"; then
                    echo ">> Adding FVM environment variables to .bashrc"
                    echo 'export PATH="$HOME/fvm/bin:$PATH"' >> "$BASHRC_FILE"
                fi
                return
            fi
            echo ">> FVM needs update: $installed_version -> $latest_version"
        else
            echo ">> FVM not installed, will install latest version${latest_version:+: $latest_version}"
        fi

        echo ">> Installing FVM..."
        curl -fsSL https://fvm.app/install.sh | bash

        if ! grep -q 'export PATH="$HOME/fvm/bin:$PATH"' "$BASHRC_FILE"; then
            echo ">> Adding FVM environment variables to .bashrc"
            echo 'export PATH="$HOME/fvm/bin:$PATH"' >> "$BASHRC_FILE"
        fi
    fi
}
# </FVM>

# <KIRO>
install_kiro() {
    if should_install "kiro"; then
        echo ">> Checking Kiro..."
        
        local update_script=""
        # Prioritize using the script in the same directory (dev environment/local run)
        if [ -f "$SCRIPT_DIR/update_kiro.sh" ]; then
            update_script="$SCRIPT_DIR/update_kiro.sh"
        # Then check common locations in Docker container
        elif [ -f "/update_kiro.sh" ]; then
            update_script="/update_kiro.sh"
        fi
        
        if [ -n "$update_script" ]; then
            echo ">> Running Kiro installer: $update_script"
            sudo chmod +x "$update_script"
            sudo DEV_HOME="$HOME" "$update_script"
            
            # Configure auto-update every 12 hours
            echo ">> Configuring Kiro auto-update (every 12 hours)..."
            if [ "$(realpath "$update_script")" != "/usr/local/bin/update_kiro.sh" ]; then
                sudo cp "$update_script" /usr/local/bin/update_kiro.sh
            fi
            sudo chmod +x /usr/local/bin/update_kiro.sh
            
            # Add crontab task
            local CRON_FILE="/etc/cron.d/kiro-update"
            echo "0 */12 * * * root DEV_HOME=\"$HOME\" /usr/local/bin/update_kiro.sh >> /var/log/cron.log 2>&1" | sudo tee "$CRON_FILE" > /dev/null
            sudo chmod 0644 "$CRON_FILE"
            echo ">> Kiro auto-update task added to $CRON_FILE"
        else
            echo "Error: update_kiro.sh not found. Cannot install Kiro."
        fi
    fi
}
# </KIRO>

# <OPENCODE>
get_opencode_latest_version() {
    curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/anomalyco/opencode/releases/latest" 2>/dev/null | \
        grep -o '"tag_name": *"[^"]*"' | \
        head -n 1 | \
        sed -E 's/.*"v?([^"]+)".*/\1/'
}

get_opencode_installed_version() {
    if command -v opencode >/dev/null 2>&1; then
        opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
    fi
}

install_opencode() {
    if should_install "opencode"; then
        echo ">> Checking Opencode..."
        
        local installed_version
        local latest_version
        installed_version=$(get_opencode_installed_version)
        latest_version=$(get_opencode_latest_version)

        if [ -n "$installed_version" ]; then
             if [ -z "$latest_version" ]; then
                echo ">> Opencode installed version: $installed_version, cannot get latest version, skipping update"
                return
            fi
            if [ "$installed_version" = "$latest_version" ]; then
                echo ">> Opencode is already the latest version: $installed_version, skipping installation"
                # Ensure symlink exists even if version is up to date
                local opencode_bin
                opencode_bin=$(command -v opencode || true)
                if [ -n "$opencode_bin" ]; then
                     local opencode_dir
                     opencode_dir=$(dirname "$opencode_bin")
                     if [ ! -e "$opencode_dir/oc" ]; then
                         echo ">> Creating symlink oc -> opencode"
                         ln -s "$opencode_bin" "$opencode_dir/oc"
                     fi
                fi
                return
            fi
            echo ">> Opencode needs update: $installed_version -> $latest_version"
        else
             echo ">> Opencode not installed, will install latest version${latest_version:+: $latest_version}"
        fi

        echo ">> Installing Opencode..."
        curl -fsSL https://opencode.ai/install | bash
        
        # Source .bashrc to update environment variables
        if [ -f "$BASHRC_FILE" ]; then
            set +e
            source "$BASHRC_FILE"
            set -e
        fi

        local opencode_bin
        opencode_bin=$(command -v opencode || true)
        
        if [ -n "$opencode_bin" ]; then
            echo ">> Opencode installed at: $opencode_bin"
            local opencode_dir
            opencode_dir=$(dirname "$opencode_bin")
            
            if [ ! -e "$opencode_dir/oc" ]; then
                echo ">> Creating symlink oc -> opencode"
                ln -s "$opencode_bin" "$opencode_dir/oc"
            fi
        else
            echo "Warning: opencode command not found after installation."
        fi
    fi
}
# </OPENCODE>

# <OPENCLAW>
install_openclaw() {
    if should_install "openclaw"; then
        echo ">> Checking Openclaw..."

        local latest_version
        local installed_version
        
        # Get latest version from npm registry
        latest_version=$(npm view openclaw version 2>/dev/null)
        
        # Get installed version from global npm modules
        # Use a regex that captures versions with hyphens (e.g., 2026.2.3-1)
        installed_version=$(npm list -g openclaw --depth=0 2>/dev/null | grep -oE 'openclaw@[^[:space:]]+' | cut -d@ -f2)

        if [ -n "$latest_version" ]; then
            if [ "$installed_version" != "$latest_version" ]; then
                echo ">> Installing/Upgrading Openclaw (Current: ${installed_version:-None}, Latest: $latest_version)..."
                npm install -g openclaw @tobilu/qmd
                mise reshim
            else
                echo ">> Openclaw is already up to date ($installed_version)."
            fi
        else
             echo "Warning: Could not fetch latest Openclaw version."
             if [ -z "$installed_version" ]; then
                 echo ">> Openclaw not detected. Attempting installation..."
                 npm install -g openclaw @tobilu/qmd
                 mise reshim
             else
                 echo ">> Openclaw seems installed ($installed_version). Skipping update due to network/registry issue."
             fi
        fi

        # Configure Openclaw settings
        echo ">> Configuring Openclaw settings..."
        mkdir -p "$HOME/.openclaw"
        local OCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
        if [ ! -f "$OCLAW_CONFIG" ]; then
            echo "{}" > "$OCLAW_CONFIG"
        fi
        
        if command -v jq >/dev/null 2>&1; then
             local TMP_CONFIG=$(mktemp)
             # Ensure nested keys exist by using objects
             jq '.gateway.bind = "lan" | .gateway.controlUi.allowInsecureAuth = true | .browser.headless = true' "$OCLAW_CONFIG" > "$TMP_CONFIG" && mv "$TMP_CONFIG" "$OCLAW_CONFIG"
             echo ">> Updated $OCLAW_CONFIG"
        else
             echo "Warning: jq not found, skipping Openclaw configuration update."
        fi

        # Configure supervisor
        local SUPERVISOR_CONF="/etc/supervisor/conf.d/supervisord.conf"
        if [ -f "$SUPERVISOR_CONF" ]; then
             if ! sudo grep -q "program:openclaw-gateway" "$SUPERVISOR_CONF"; then
                 echo ">> Adding Openclaw to supervisor config..."
                 sudo bash -c "cat >> $SUPERVISOR_CONF <<EOF

[program:openclaw-gateway]
command=/home/dev/.local/share/mise/installs/node/latest/bin/node /home/dev/.local/share/mise/installs/node/latest/lib/node_modules/openclaw/dist/index.js gateway --port 18789
user=dev
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/openclaw-gateway.log
environment=HOME=\"/home/dev\",PATH=\"/home/dev/.local/share/mise/installs/node/latest/bin:/home/dev/.local/bin:/home/dev/.npm-global/bin:/home/dev/bin:/home/dev/.fnm/current/bin:/home/dev/.volta/bin:/home/dev/.asdf/shims:/home/dev/.local/share/pnpm:/home/dev/.bun/bin:/usr/local/bin:/usr/bin:/bin\"
EOF"
             fi
        fi
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)" && brew tap yakitrak/yakitrak && brew install yakitrak/yakitrak/obsidian-cli
    fi
}
# </OPENCLAW>

# <CODEX>
get_codex_monitor_release_json() {
    curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/Dimillian/CodexMonitor/releases/latest" 2>/dev/null || true
}

get_codex_monitor_installed_version() {
    local marker_file="/usr/local/share/codex-monitor/version"
    if [ -x "/usr/bin/codex-monitor" ] && [ -f "$marker_file" ]; then
        tr -d '[:space:]' < "$marker_file" 2>/dev/null || true
    fi
}

install_codex_monitor_from_rpm() {
    local rpm_path="$1"
    local version="$2"
    local tmp_dir
    local payload_archive
    local payload_root

    tmp_dir=$(mktemp -d)

    if ! 7z x -y "$rpm_path" -o"$tmp_dir" >/dev/null; then
        echo "Error: Failed to extract Codex Monitor RPM."
        rm -rf "$tmp_dir"
        return 1
    fi

    payload_archive=$(find "$tmp_dir" -maxdepth 1 -type f -name '*.cpio*' | head -n 1)
    if [ -z "$payload_archive" ]; then
        echo "Error: Could not find CPIO payload in RPM."
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! 7z x -y "$payload_archive" -o"$tmp_dir/payload" >/dev/null; then
        echo "Error: Failed to extract Codex Monitor CPIO payload."
        rm -rf "$tmp_dir"
        return 1
    fi

    payload_root="$tmp_dir/payload"
    if [ ! -d "$payload_root/usr" ]; then
        local nested_cpio
        nested_cpio=$(find "$payload_root" -maxdepth 1 -type f -name '*.cpio' | head -n 1)
        if [ -n "$nested_cpio" ]; then
            mkdir -p "$tmp_dir/payload-final"
            if ! 7z x -y "$nested_cpio" -o"$tmp_dir/payload-final" >/dev/null; then
                echo "Error: Failed to extract nested Codex Monitor CPIO payload."
                rm -rf "$tmp_dir"
                return 1
            fi
            payload_root="$tmp_dir/payload-final"
        fi
    fi

    if [ ! -d "$payload_root/usr" ]; then
        echo "Error: Invalid Codex Monitor payload, /usr not found after extraction."
        rm -rf "$tmp_dir"
        return 1
    fi

    sudo cp -a "$payload_root/usr/." /usr/
    sudo install -d /usr/local/share/codex-monitor
    echo "$version" | sudo tee /usr/local/share/codex-monitor/version > /dev/null

    rm -rf "$tmp_dir"
}

install_codex() {
    if should_install "codex"; then
        echo ">> Checking Codex..."
        
        local latest_version
        local installed_version
        
        # Get latest version from npm registry
        latest_version=$(npm view @openai/codex version 2>/dev/null)
        
        # Get installed version from global npm modules
        # Pattern matches @openai/codex@version
        installed_version=$(npm list -g @openai/codex --depth=0 2>/dev/null | grep -oE '@openai/codex@[^[:space:]]+' | cut -d@ -f3)

        if [ -n "$latest_version" ]; then
            if [ "$installed_version" != "$latest_version" ]; then
                echo ">> Installing/Upgrading Codex (Current: ${installed_version:-None}, Latest: $latest_version)..."
                npm install -g @openai/codex
                mise reshim
            else
                echo ">> Codex is already up to date ($installed_version)."
            fi
        else
             echo "Warning: Could not fetch latest Codex version."
             if [ -z "$installed_version" ]; then
                 echo ">> Codex not detected. Attempting installation..."
                 npm install -g @openai/codex
                 mise reshim
             else
                 echo ">> Codex seems installed ($installed_version). Skipping update due to network/registry issue."
             fi
        fi

        echo ">> Checking Codex Monitor..."
        local monitor_release_json
        local monitor_latest_version
        local monitor_installed_version
        local monitor_rpm_name
        local monitor_rpm_url
        local monitor_cache_dir
        local monitor_cached_rpm

        monitor_release_json=$(get_codex_monitor_release_json)
        monitor_latest_version=$(echo "$monitor_release_json" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
        monitor_installed_version=$(get_codex_monitor_installed_version)
        monitor_cache_dir="$HOME/.cache/auto_install/codex-monitor"
        if ! mkdir -p "$monitor_cache_dir" 2>/dev/null; then
            echo ">> Fixing cache directory permissions for Codex Monitor..."
            sudo mkdir -p "$HOME/.cache/auto_install"
            sudo chown -R "$(id -u):$(id -g)" "$HOME/.cache/auto_install"
            mkdir -p "$monitor_cache_dir"
        fi

        if [ -n "$monitor_latest_version" ]; then
            if [ "$monitor_installed_version" = "$monitor_latest_version" ] && [ -x "/usr/bin/codex-monitor" ]; then
                echo ">> Codex Monitor is already up to date ($monitor_installed_version)."
            else
                monitor_rpm_name=$(echo "$monitor_release_json" | jq -r '.assets[]? | select(.name | test("\\.x86_64\\.rpm$")) | .name' 2>/dev/null | head -n 1)
                monitor_rpm_url=$(echo "$monitor_release_json" | jq -r '.assets[]? | select(.name | test("\\.x86_64\\.rpm$")) | .browser_download_url' 2>/dev/null | head -n 1)

                if [ -z "$monitor_rpm_name" ] || [ -z "$monitor_rpm_url" ]; then
                    echo "Warning: Could not find x86_64 RPM asset for Codex Monitor."
                else
                    monitor_cached_rpm="$monitor_cache_dir/$monitor_rpm_name"
                    if [ -f "$monitor_cached_rpm" ]; then
                        echo ">> Using cached Codex Monitor RPM: $monitor_cached_rpm"
                    else
                        echo ">> Downloading Codex Monitor RPM: $monitor_rpm_name"
                        curl -fL --connect-timeout 15 --max-time 300 -o "$monitor_cached_rpm" "$monitor_rpm_url"
                    fi

                    echo ">> Installing/Upgrading Codex Monitor (Current: ${monitor_installed_version:-None}, Latest: $monitor_latest_version)..."
                    install_codex_monitor_from_rpm "$monitor_cached_rpm" "$monitor_latest_version"
                fi
            fi
        else
            if [ -x "/usr/bin/codex-monitor" ]; then
                echo "Warning: Could not fetch latest Codex Monitor version. Existing installation detected, skipping update."
            else
                monitor_cached_rpm=$(ls -t "$monitor_cache_dir"/*.rpm 2>/dev/null | head -n 1 || true)
                if [ -n "$monitor_cached_rpm" ]; then
                    local cached_version
                    cached_version=$(echo "$(basename "$monitor_cached_rpm")" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
                    echo "Warning: Could not fetch latest Codex Monitor version. Installing from cached RPM: $(basename "$monitor_cached_rpm")"
                    install_codex_monitor_from_rpm "$monitor_cached_rpm" "${cached_version:-unknown}"
                else
                    echo "Warning: Could not fetch latest Codex Monitor version and no cached RPM is available."
                fi
            fi
        fi
    fi
}
# </CODEX>

# <CODE>
install_code() {
    if should_install "code"; then
        echo ">> Checking VS Code..."

        # Always check for GPG key and repo source to ensure they are correct
        # This also allows upgrading if the repo source was missing or key was updated

        if [ ! -f "/usr/share/keyrings/microsoft.gpg" ]; then
             echo ">> Installing Microsoft GPG key..."
             wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
             sudo install -D -o root -g root -m 644 microsoft.gpg /usr/share/keyrings/microsoft.gpg
             rm -f microsoft.gpg
        fi

        # Check and add repository
        local VSCODE_SOURCE="/etc/apt/sources.list.d/vscode.sources"
        if [ ! -f "$VSCODE_SOURCE" ]; then
            echo ">> Adding VS Code repository to $VSCODE_SOURCE..."
            cat <<EOF | sudo tee "$VSCODE_SOURCE" > /dev/null
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
            echo ">> Updating APT cache for VS Code..."
            sudo apt-get update
            export APT_UPDATED=true
        else
            # Ensure apt cache is updated if we are going to install/upgrade
            update_apt_cache
        fi

        echo ">> Installing/Upgrading code package..."
        sudo apt-get install -y code
    fi
}
# </CODE>

setup_ai_cron() {
    # Install the update script if available
    if [ -f "/update_ai_tools.sh" ]; then
        echo ">> Installing update_ai_tools.sh..."
        sudo cp /update_ai_tools.sh /usr/local/bin/update_ai_tools.sh
        sudo chmod +x /usr/local/bin/update_ai_tools.sh
    fi

    local tools_to_update=""
    if should_install "gemini"; then
        tools_to_update="${tools_to_update}gemini,"
    fi
    if should_install "claude"; then
        tools_to_update="${tools_to_update}claude,"
    fi
    if should_install "codex"; then
        tools_to_update="${tools_to_update}codex,"
    fi
    
    # Remove trailing comma
    tools_to_update=${tools_to_update%,}
    local CRON_FILE="/etc/cron.d/ai-tools-update"

    if [ -n "$tools_to_update" ]; then
        echo ">> Configuring auto-update cron for: $tools_to_update (every 12h)"
        # Run the dedicated update script
        local CRON_CONTENT="0 */12 * * * root AUTO_INSTALL=\"$tools_to_update\" /usr/local/bin/update_ai_tools.sh >> /var/log/ai-tools-update.log 2>&1"
        
        # Write to temp file first to avoid sudo redirection issues
        echo "$CRON_CONTENT" | sudo tee "$CRON_FILE" > /dev/null
        sudo chmod 0644 "$CRON_FILE"
    else
        # Clean up if no AI tools are installed
        if [ -f "$CRON_FILE" ]; then
             echo ">> Removing auto-update cron (no AI tools selected)..."
             sudo rm -f "$CRON_FILE"
        fi
    fi
}


echo ">> Starting tools installation (User: $(whoami))..."

configure_mise
install_antigravity
install_kiro
install_fvm
install_opencode
install_openclaw
install_codex
install_code
setup_ai_cron

echo ">> Tools installation completed."
