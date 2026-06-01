#!/usr/bin/env bash

set -euo pipefail

# Use DEV_HOME so cache survives container recreation when only /home/dev is persisted.
DEV_HOME="${DEV_HOME:-/home/dev}"
if [ ! -d "$DEV_HOME" ]; then
    DEV_HOME="$HOME"
fi

if [ "$(id -u)" -ne 0 ]; then
    exec sudo DEV_HOME="$DEV_HOME" bash "$0" "$@"
fi

DOWNLOAD_PAGE_URL="https://antigravity.google/download"
ANTIGRAVITY_RELEASES_API_DEFAULT="https://antigravity-auto-updater-974169037036.us-central1.run.app/releases"
ANTIGRAVITY_IDE_RELEASES_API_DEFAULT="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases"
ANTIGRAVITY_CLI_INSTALL_SCRIPT_URL="https://antigravity.google/cli/install.sh"
ANTIGRAVITY_CLI_DOWNLOAD_BASE_DEFAULT="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"

ANTIGRAVITY_RELEASES_API="$ANTIGRAVITY_RELEASES_API_DEFAULT"
ANTIGRAVITY_IDE_RELEASES_API="$ANTIGRAVITY_IDE_RELEASES_API_DEFAULT"

CACHE_DIR="$DEV_HOME/.cache/auto_install/antigravity"
STATE_DIR="/usr/local/share/openstation/antigravity"
BIN_DIR="/usr/local/bin"
APP_DIR="/opt"
APPLICATIONS_DIR="/usr/local/share/applications"

mkdir -p "$CACHE_DIR" "$STATE_DIR" "$BIN_DIR" "$APPLICATIONS_DIR"

# Keep cache directory writable by the persisted user home owner.
DEV_UID=$(stat -c '%u' "$DEV_HOME" 2>/dev/null || true)
DEV_GID=$(stat -c '%g' "$DEV_HOME" 2>/dev/null || true)
if [ -n "$DEV_UID" ] && [ -n "$DEV_GID" ]; then
    chown "$DEV_UID:$DEV_GID" "$DEV_HOME/.cache" "$DEV_HOME/.cache/auto_install" "$CACHE_DIR" 2>/dev/null || true
fi

DOWNLOAD_JS_FILE=""
TMP_DIRS=()

cleanup() {
    if [ -n "$DOWNLOAD_JS_FILE" ]; then
        rm -f "$DOWNLOAD_JS_FILE"
    fi

    local tmp_dir
    for tmp_dir in "${TMP_DIRS[@]:-}"; do
        rm -rf "$tmp_dir"
    done
}
trap cleanup EXIT

case "$(uname -m)" in
    x86_64|amd64)
        DOWNLOAD_PLATFORM="linux-x64"
        CLI_PLATFORM="linux_amd64"
        ;;
    arm64|aarch64)
        DOWNLOAD_PLATFORM="linux-arm"
        CLI_PLATFORM="linux_arm64"
        ;;
    *)
        echo "Error: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

safe_name() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

cache_key_for_url() {
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 16)}'
}

parse_json_key() {
    local payload="$1"
    local key="$2"
    printf '%s\n' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

fetch_download_js() {
    if [ -n "$DOWNLOAD_JS_FILE" ] && [ -s "$DOWNLOAD_JS_FILE" ]; then
        return 0
    fi

    local html
    local js_path
    local js_paths
    local js_url
    local fetched_any="false"

    echo ">> Fetching Antigravity download page metadata..." >&2
    html=$(curl --compressed -fsSL "$DOWNLOAD_PAGE_URL")
    js_paths=$(printf '%s\n' "$html" | tr "'" '"' | \
        grep -oE '<[^>]+(src|href)[[:space:]]*=[[:space:]]*"[^"]+\.js([^"]*)?"' | \
        sed -E 's/.*(src|href)[[:space:]]*=[[:space:]]*"([^"]+)".*/\2/' | \
        awk '!seen[$0]++' || true)

    if [ -z "$js_paths" ]; then
        echo "Error: Cannot find Antigravity JavaScript bundles from $DOWNLOAD_PAGE_URL" >&2
        exit 1
    fi

    DOWNLOAD_JS_FILE=$(mktemp)

    while IFS= read -r js_path; do
        [ -z "$js_path" ] && continue

        case "$js_path" in
            https://antigravity.google/*)
                js_url="$js_path"
                ;;
            http://*|https://*)
                continue
                ;;
            /*)
                js_url="https://antigravity.google${js_path}"
                ;;
            *)
                js_url="https://antigravity.google/${js_path}"
                ;;
        esac

        echo ">> Fetching Antigravity download metadata script: $js_url" >&2
        if curl --compressed -fsSL "$js_url" >> "$DOWNLOAD_JS_FILE"; then
            printf '\n' >> "$DOWNLOAD_JS_FILE"
            fetched_any="true"
        else
            echo "Warning: Failed to fetch Antigravity script: $js_url" >&2
        fi
    done <<< "$js_paths"

    if [ "$fetched_any" != "true" ]; then
        echo "Error: Cannot fetch any same-origin Antigravity JavaScript bundle." >&2
        exit 1
    fi
}

list_download_js_urls() {
    fetch_download_js
    tr "\"'\`" '\n' < "$DOWNLOAD_JS_FILE" | grep -E '^https?://' || true
}

extract_download_js_url() {
    local pattern="$1"
    list_download_js_urls | grep -E "$pattern" | head -n 1 || true
}

discover_release_endpoints() {
    local api_url

    api_url=$(extract_download_js_url 'https?://[^/]*antigravity-auto-updater[^/]*/releases$')
    if [ -n "$api_url" ]; then
        ANTIGRAVITY_RELEASES_API="$api_url"
    fi

    api_url=$(extract_download_js_url 'https?://[^/]*antigravity-ide-auto-updater[^/]*/releases$')
    if [ -n "$api_url" ]; then
        ANTIGRAVITY_IDE_RELEASES_API="$api_url"
    fi
}

latest_v2_release_from_api() {
    local api_url="$1"
    local releases

    releases=$(curl -fsSL "$api_url")

    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$releases" | jq -r '
            (if type == "array" then . else .versions // [] end)
            | map(select(.version | test("^2\\.")))
            | sort_by(.version | split(".") | map(tonumber? // 0))
            | reverse
            | .[0]
            | select(. != null)
            | "\(.version) \(.execution_id)"
        '
        return 0
    fi

    printf '%s\n' "$releases" | tr '{' '\n' | while IFS= read -r item; do
        local version
        local execution_id
        version=$(parse_json_key "{$item" "version")
        execution_id=$(parse_json_key "{$item" "execution_id")
        if [[ "$version" == 2.* ]] && [ -n "$execution_id" ]; then
            printf '%s %s\n' "$version" "$execution_id"
            break
        fi
    done
}

resolve_antigravity_2_url() {
    local url
    local release
    local version
    local execution_id

    url=$(extract_download_js_url "https?://.*/antigravity-hub/.*/${DOWNLOAD_PLATFORM}/Antigravity\\.tar\\.gz([?#].*)?$")
    if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi

    echo "Warning: Could not find Antigravity 2.0 direct URL in main.js, falling back to releases API." >&2
    release=$(latest_v2_release_from_api "$ANTIGRAVITY_RELEASES_API")
    version=$(echo "$release" | awk '{print $1}')
    execution_id=$(echo "$release" | awk '{print $2}')
    if [ -z "$version" ] || [ -z "$execution_id" ]; then
        echo "Error: Cannot resolve Antigravity 2.0 download URL" >&2
        exit 1
    fi

    printf 'https://storage.googleapis.com/antigravity-public/antigravity-hub/%s-%s/%s/Antigravity.tar.gz\n' "$version" "$execution_id" "$DOWNLOAD_PLATFORM"
}

resolve_antigravity_ide_url() {
    local url
    local release
    local version
    local execution_id

    url=$(extract_download_js_url "https?://.*/antigravity/stable/.*/${DOWNLOAD_PLATFORM}/Antigravity%20IDE\\.tar\\.gz([?#].*)?$")
    if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi

    echo "Warning: Could not find Antigravity IDE direct URL in main.js, falling back to releases API." >&2
    release=$(latest_v2_release_from_api "$ANTIGRAVITY_IDE_RELEASES_API")
    version=$(echo "$release" | awk '{print $1}')
    execution_id=$(echo "$release" | awk '{print $2}')
    if [ -z "$version" ] || [ -z "$execution_id" ]; then
        echo "Error: Cannot resolve Antigravity IDE download URL" >&2
        exit 1
    fi

    printf 'https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/%s-%s/%s/Antigravity%%20IDE.tar.gz\n' "$version" "$execution_id" "$DOWNLOAD_PLATFORM"
}

download_file() {
    local url="$1"
    local target_file="$2"
    local temp_file="${target_file}.part.$$"

    rm -f "$temp_file" "$temp_file.aria2"
    echo ">> Downloading: $url" >&2

    if command -v aria2c >/dev/null 2>&1; then
        aria2c -x 16 -s 16 -d "$(dirname "$temp_file")" -o "$(basename "$temp_file")" "$url" >&2
    else
        curl -fL --retry 3 --retry-delay 2 -o "$temp_file" "$url" >&2
    fi

    mv -f "$temp_file" "$target_file"
    rm -f "$temp_file.aria2"
}

is_valid_tar_gz() {
    local tar_file="$1"
    [ -f "$tar_file" ] && tar -tzf "$tar_file" >/dev/null 2>&1
}

ensure_cached_tar_gz() {
    local slug="$1"
    local url="$2"
    local cache_file="$CACHE_DIR/${slug}-$(cache_key_for_url "$url").tar.gz"

    if [ -f "$cache_file" ] && ! is_valid_tar_gz "$cache_file"; then
        echo "Warning: Cached archive is invalid, removing: $cache_file" >&2
        rm -f "$cache_file"
    fi

    if [ ! -f "$cache_file" ]; then
        download_file "$url" "$cache_file"
    else
        echo ">> Using cached archive: $cache_file" >&2
    fi

    if ! is_valid_tar_gz "$cache_file"; then
        echo "Error: Downloaded archive is invalid: $cache_file" >&2
        rm -f "$cache_file"
        exit 1
    fi

    printf '%s\n' "$cache_file"
}

find_icon_for_app() {
    local install_dir="$1"
    local icon

    icon=$(find "$install_dir" -maxdepth 6 -type f \( -iname '*antigravity*.png' -o -iname 'code.png' \) 2>/dev/null | sort | head -n 1 || true)
    if [ -n "$icon" ]; then
        printf '%s\n' "$icon"
    fi
}

write_desktop_entry() {
    local desktop_file="$1"
    local display_name="$2"
    local exec_path="$3"
    local icon_path="$4"
    local target_file="$APPLICATIONS_DIR/$desktop_file"

    {
        echo "[Desktop Entry]"
        echo "Name=$display_name"
        echo "Exec=$exec_path %F"
        if [ -n "$icon_path" ]; then
            echo "Icon=$icon_path"
        fi
        echo "Type=Application"
        echo "Terminal=false"
        echo "Categories=Development;IDE;"
        echo "StartupNotify=false"
    } > "$target_file"
    chmod 0644 "$target_file"
}

configure_electron_sandbox() {
    local install_dir="$1"
    local sandbox_binary="$install_dir/chrome-sandbox"

    if [ -f "$sandbox_binary" ]; then
        chown root:root "$sandbox_binary"
        chmod 4755 "$sandbox_binary"
    fi
}

resolve_cli_manifest_url() {
    local install_script
    local base_url

    install_script=$(curl -fsSL "$ANTIGRAVITY_CLI_INSTALL_SCRIPT_URL" 2>/dev/null || true)
    base_url=$(printf '%s\n' "$install_script" | sed -n 's/^DOWNLOAD_BASE_URL="\([^"]*\)".*/\1/p' | head -n 1)

    if [ -z "$base_url" ]; then
        base_url=$(printf '%s\n' "$install_script" | grep -oE 'https?://[^" ]*antigravity-cli[^" ]*' | sed 's#/manifests/.*##' | head -n 1 || true)
    fi

    if [ -z "$base_url" ]; then
        base_url="$ANTIGRAVITY_CLI_DOWNLOAD_BASE_DEFAULT"
    fi

    printf '%s/manifests/%s.json\n' "$base_url" "$CLI_PLATFORM"
}

install_tar_app() {
    local slug="$1"
    local display_name="$2"
    local url="$3"
    local binary_name="$4"
    local symlink_name="$5"
    local install_dir="$6"
    local desktop_file="$7"
    local marker_file="$STATE_DIR/${slug}.url"
    local target_binary="$install_dir/$binary_name"
    local cache_file
    local extract_dir
    local extracted_binary
    local extracted_root
    local icon_path

    if [ -x "$target_binary" ] && [ -f "$marker_file" ] && [ "$(cat "$marker_file")" = "$url" ]; then
        echo ">> $display_name is up to date."
        ln -sfn "$target_binary" "$BIN_DIR/$symlink_name"
        return 0
    fi

    echo ">> Installing $display_name..."
    cache_file=$(ensure_cached_tar_gz "$slug" "$url")
    extract_dir=$(mktemp -d)
    TMP_DIRS+=("$extract_dir")

    tar -xzf "$cache_file" -C "$extract_dir"
    extracted_binary=$(find "$extract_dir" -maxdepth 3 -type f -name "$binary_name" | head -n 1 || true)

    if [ -z "$extracted_binary" ]; then
        echo "Error: Cannot find $binary_name in $cache_file" >&2
        exit 1
    fi

    chmod +x "$extracted_binary"
    extracted_root=$(dirname "$extracted_binary")

    rm -rf "$install_dir"
    mkdir -p "$(dirname "$install_dir")"
    mv "$extracted_root" "$install_dir"

    configure_electron_sandbox "$install_dir"
    ln -sfn "$target_binary" "$BIN_DIR/$symlink_name"
    icon_path=$(find_icon_for_app "$install_dir")
    write_desktop_entry "$desktop_file" "$display_name" "$BIN_DIR/$symlink_name" "$icon_path"
    printf '%s\n' "$url" > "$marker_file"

    echo ">> Installed $display_name to $install_dir"
}

install_antigravity_cli() {
    local manifest_url
    local manifest
    local version
    local url
    local sha512
    local marker_file="$STATE_DIR/antigravity-cli.url"
    local cache_file
    local extract_dir
    local extracted_binary
    local actual_sha512

    echo ">> Checking Antigravity CLI..."
    manifest_url=$(resolve_cli_manifest_url)
    manifest=$(curl -fsSL "$manifest_url")
    version=$(parse_json_key "$manifest" "version")
    url=$(parse_json_key "$manifest" "url")
    sha512=$(parse_json_key "$manifest" "sha512")

    if [ -z "$url" ] || [ -z "$sha512" ]; then
        echo "Error: Cannot parse Antigravity CLI manifest: $manifest_url" >&2
        exit 1
    fi

    if [ -x "$BIN_DIR/agy" ] && [ -f "$marker_file" ] && [ "$(cat "$marker_file")" = "$url" ]; then
        echo ">> Antigravity CLI is up to date (${version:-unknown})."
        ln -sfn "$BIN_DIR/agy" "$BIN_DIR/antigravity-cli"
        return 0
    fi

    echo ">> Installing Antigravity CLI (${version:-unknown})..."
    cache_file="$CACHE_DIR/antigravity-cli-$(safe_name "${version:-unknown}")-$(cache_key_for_url "$url").tar.gz"

    if [ -f "$cache_file" ] && ! is_valid_tar_gz "$cache_file"; then
        echo "Warning: Cached CLI archive is invalid, removing: $cache_file" >&2
        rm -f "$cache_file"
    fi
    if [ ! -f "$cache_file" ]; then
        download_file "$url" "$cache_file"
    else
        echo ">> Using cached archive: $cache_file" >&2
    fi

    actual_sha512=$(sha512sum "$cache_file" | awk '{print $1}')
    if [ "$actual_sha512" != "$sha512" ]; then
        echo "Error: Antigravity CLI checksum mismatch." >&2
        rm -f "$cache_file"
        exit 1
    fi

    extract_dir=$(mktemp -d)
    TMP_DIRS+=("$extract_dir")
    tar -xzf "$cache_file" -C "$extract_dir"
    extracted_binary=$(find "$extract_dir" -maxdepth 3 -type f -name antigravity | head -n 1 || true)

    if [ -z "$extracted_binary" ]; then
        echo "Error: Cannot find Antigravity CLI binary in $cache_file" >&2
        exit 1
    fi

    rm -f "$BIN_DIR/agy"
    install -m 0755 "$extracted_binary" "$BIN_DIR/agy"
    ln -sfn "$BIN_DIR/agy" "$BIN_DIR/antigravity-cli"
    printf '%s\n' "$url" > "$marker_file"

    echo ">> Installed Antigravity CLI to $BIN_DIR/agy"
}

remove_legacy_apt_source() {
    rm -f /etc/apt/sources.list.d/antigravity.list /etc/apt/keyrings/antigravity-repo-key.gpg 2>/dev/null || true
}

main() {
    local antigravity_2_url
    local antigravity_ide_url

    echo ">> Checking Antigravity packages for $DOWNLOAD_PLATFORM..."
    remove_legacy_apt_source

    fetch_download_js
    discover_release_endpoints
    antigravity_2_url=$(resolve_antigravity_2_url)
    antigravity_ide_url=$(resolve_antigravity_ide_url)

    install_tar_app \
        "antigravity-2" \
        "Google Antigravity" \
        "$antigravity_2_url" \
        "antigravity" \
        "antigravity" \
        "$APP_DIR/antigravity" \
        "google-antigravity.desktop"

    install_tar_app \
        "antigravity-ide" \
        "Google Antigravity IDE" \
        "$antigravity_ide_url" \
        "antigravity-ide" \
        "antigravity-ide" \
        "$APP_DIR/antigravity-ide" \
        "google-antigravity-ide.desktop"

    install_antigravity_cli
}

main "$@"
