#!/bin/bash

set -e

# Use DEV_HOME so cache survives container recreation when only /home/dev is persisted.
DEV_HOME="${DEV_HOME:-/home/dev}"
if [ ! -d "$DEV_HOME" ]; then
    DEV_HOME="$HOME"
fi
CACHE_DIR="$DEV_HOME/.cache/auto_install/kiro"
mkdir -p "$CACHE_DIR"

# Keep cache directory writable by the persisted user home owner.
if [ "$(id -u)" -eq 0 ]; then
    DEV_UID=$(stat -c '%u' "$DEV_HOME" 2>/dev/null || true)
    DEV_GID=$(stat -c '%g' "$DEV_HOME" 2>/dev/null || true)
    if [ -n "$DEV_UID" ] && [ -n "$DEV_GID" ]; then
        chown "$DEV_UID:$DEV_GID" "$DEV_HOME/.cache" "$DEV_HOME/.cache/auto_install" "$CACHE_DIR" 2>/dev/null || true
    fi
fi

is_valid_deb() {
    local deb_file="$1"
    [ -f "$deb_file" ] && dpkg-deb -I "$deb_file" >/dev/null 2>&1
}

find_latest_valid_cached_deb() {
    local cached_file
    while IFS= read -r cached_file; do
        [ -z "$cached_file" ] && continue
        if is_valid_deb "$cached_file"; then
            echo "$cached_file"
            return 0
        fi
        echo "Warning: Removing invalid cached package: $cached_file"
        rm -f "$cached_file"
    done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name 'kiro-*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
    return 1
}

cleanup_old_cached_debs() {
    local keep_file="$1"
    local keep_count=2
    local idx=0
    local cached_file

    while IFS= read -r cached_file; do
        [ -z "$cached_file" ] && continue
        if [ "$cached_file" = "$keep_file" ]; then
            continue
        fi
        idx=$((idx + 1))
        if [ "$idx" -ge "$keep_count" ]; then
            rm -f "$cached_file"
        fi
    done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name 'kiro-*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

download_kiro_deb() {
    local target_deb="$1"
    local deb_url="$2"
    local temp_deb="${target_deb}.part.$$"

    rm -f "$temp_deb" "$temp_deb.aria2"
    if ! aria2c -x 16 -s 16 -d "$CACHE_DIR" -o "$(basename "$temp_deb")" "$deb_url"; then
        rm -f "$temp_deb" "$temp_deb.aria2"
        return 1
    fi

    if ! is_valid_deb "$temp_deb"; then
        echo "Warning: Downloaded Kiro DEB is invalid, deleting incomplete file."
        rm -f "$temp_deb" "$temp_deb.aria2"
        return 1
    fi

    mv -f "$temp_deb" "$target_deb"
    rm -f "$temp_deb.aria2"
    return 0
}

get_kiro_installed_version() {
    dpkg-query -W -f='${Version}' kiro 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true
}

echo ">> Checking Kiro..."

INSTALLED_VER=$(get_kiro_installed_version)
METADATA_URL="https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json"
DOWNLOAD_URL=$(curl -fsSL --connect-timeout 10 --max-time 30 "$METADATA_URL" 2>/dev/null | jq -r '.releases[] | .updateTo.url | select(endswith(".tar.gz"))' | head -n 1 || true)
LATEST_VER=$(echo "$DOWNLOAD_URL" | grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | head -n 1 | tr -d '/' || true)

if [ -n "$LATEST_VER" ]; then
    SAFE_VER=$(echo "$LATEST_VER" | sed 's/[^A-Za-z0-9._-]/_/g')
    CACHE_DEB="$CACHE_DIR/kiro-${SAFE_VER}.deb"

    rm -f "$CACHE_DIR"/kiro-*.deb.part.* "$CACHE_DIR"/kiro-*.deb.part.*.aria2 2>/dev/null || true

    if [ -f "$CACHE_DEB" ] && ! is_valid_deb "$CACHE_DEB"; then
        echo "Warning: Cached package is invalid, removing: $CACHE_DEB"
        rm -f "$CACHE_DEB"
    fi
fi

if [ -n "$INSTALLED_VER" ]; then
    if [ -z "$LATEST_VER" ]; then
        echo ">> Kiro installed ($INSTALLED_VER), but cannot fetch latest version. Skipping update."
        exit 0
    fi
    if [ "$INSTALLED_VER" == "$LATEST_VER" ]; then
        echo ">> Kiro is up to date ($INSTALLED_VER)."
        cleanup_old_cached_debs "$CACHE_DEB"
        exit 0
    fi
    echo ">> Kiro update needed: $INSTALLED_VER -> $LATEST_VER"
else
    echo ">> Kiro not installed. Installing latest version${LATEST_VER:+: $LATEST_VER}..."
fi

if [ -z "$LATEST_VER" ]; then
    CACHED_DEB=$(find_latest_valid_cached_deb || true)
    if [ -n "$CACHED_DEB" ]; then
        echo ">> Latest version unknown, falling back to cached package: $CACHED_DEB"
        dpkg -i "$CACHED_DEB" || apt-get install -f -y
        cleanup_old_cached_debs "$CACHED_DEB"
        echo ">> Kiro installation/update complete (from cache fallback)."
        exit 0
    fi
    echo "Error: Failed to fetch latest Kiro version and no cached package is available"
    exit 1
fi

if [ -f "$CACHE_DEB" ]; then
    echo ">> Using cached Kiro DEB: $CACHE_DEB"
else
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        echo "Error: Failed to find Kiro download URL"
        exit 1
    fi

    # Transform URL to DEB
    # e.g. .../tar/kiro-0.1.0.tar.gz -> .../deb/kiro-0.1.0.deb
    DEB_URL="${DOWNLOAD_URL//\/tar\//\/deb\/}"
    DEB_URL="${DEB_URL//.tar.gz/.deb}"

    echo ">> Downloading Kiro DEB from: $DEB_URL"
    if ! download_kiro_deb "$CACHE_DEB" "$DEB_URL"; then
        echo "Error: Failed to download a valid Kiro DEB package."
        exit 1
    fi
fi

if [ ! -f "$CACHE_DEB" ]; then
    echo "Error: Download failed"
    exit 1
fi

echo ">> Installing Kiro..."
dpkg -i "$CACHE_DEB" || apt-get install -f -y
cleanup_old_cached_debs "$CACHE_DEB"

echo ">> Kiro installation/update complete."
