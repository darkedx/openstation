#!/bin/bash

set -e

# Use DEV_HOME so cache survives container recreation when only /home/dev is persisted.
DEV_HOME="${DEV_HOME:-/home/dev}"
if [ ! -d "$DEV_HOME" ]; then
    DEV_HOME="$HOME"
fi

CACHE_DIR="$DEV_HOME/.cache/auto_install/antigravity"
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
    done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name 'antigravity-*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

download_antigravity_deb() {
    local target_deb="$1"
    local temp_deb="${target_deb}.part.$$"
    local deb_url=""
    local downloaded_deb=""
    local tmp_download_dir=""

    rm -f "$temp_deb" "$temp_deb.aria2"
    deb_url=$(apt-get install --reinstall --print-uris antigravity | grep -oE "https?://[^']+" | head -n 1)

    if [ -n "$deb_url" ]; then
        echo ">> Downloading from: $deb_url"
        if ! aria2c -x 16 -s 16 -d "$CACHE_DIR" -o "$(basename "$temp_deb")" "$deb_url"; then
            rm -f "$temp_deb" "$temp_deb.aria2"
            return 1
        fi
    else
        echo "Warning: Could not get URL from apt-get, falling back to apt-get download"
        tmp_download_dir=$(mktemp -d)
        if ! (cd "$tmp_download_dir" && apt-get download antigravity); then
            rm -rf "$tmp_download_dir"
            return 1
        fi
        downloaded_deb=$(ls -t "$tmp_download_dir"/antigravity_*.deb 2>/dev/null | head -n 1 || true)
        if [ -z "$downloaded_deb" ]; then
            rm -rf "$tmp_download_dir"
            return 1
        fi
        mv -f "$downloaded_deb" "$temp_deb"
        rm -rf "$tmp_download_dir"
    fi

    if ! is_valid_deb "$temp_deb"; then
        echo "Warning: Downloaded Antigravity DEB is invalid, deleting incomplete file."
        rm -f "$temp_deb" "$temp_deb.aria2"
        return 1
    fi

    mv -f "$temp_deb" "$target_deb"
    rm -f "$temp_deb.aria2"
    return 0
}

# Get versions
INSTALLED_VER=""
if dpkg-query -W -f='${Status}' antigravity 2>/dev/null | grep -q "install ok installed"; then
    INSTALLED_VER=$(dpkg-query -W -f='${Version}' antigravity 2>/dev/null)
fi

# Update apt cache
apt-get update

LATEST_VER=$(LC_ALL=C apt-cache policy antigravity | grep 'Candidate:' | awk '{print $2}')

if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "(none)" ]; then
    echo "Error: Cannot find antigravity candidate version"
    echo "Debug: apt-cache policy output:"
    LC_ALL=C apt-cache policy antigravity
    exit 1
fi

SAFE_VER=$(echo "$LATEST_VER" | sed 's/[^A-Za-z0-9._-]/_/g')
CACHE_DEB="$CACHE_DIR/antigravity-${SAFE_VER}.deb"

rm -f "$CACHE_DIR"/antigravity-*.deb.part.* "$CACHE_DIR"/antigravity-*.deb.part.*.aria2 2>/dev/null || true

if [ -f "$CACHE_DEB" ] && ! is_valid_deb "$CACHE_DEB"; then
    echo "Warning: Cached package is invalid, removing: $CACHE_DEB"
    rm -f "$CACHE_DEB"
fi

if [ "$INSTALLED_VER" == "$LATEST_VER" ]; then
    echo "Antigravity is up to date ($INSTALLED_VER)"
    cleanup_old_cached_debs "$CACHE_DEB"
    exit 0
fi

echo "Updating Antigravity: ${INSTALLED_VER:-none} -> $LATEST_VER"

if [ -f "$CACHE_DEB" ]; then
    echo "Using cached package: $CACHE_DEB"
else
    echo "Downloading Antigravity DEB..."
    if ! download_antigravity_deb "$CACHE_DEB"; then
        echo "Error: Failed to download a valid Antigravity DEB package."
        exit 1
    fi
fi

if [ -f "$CACHE_DEB" ]; then
    echo "Installing from cache: $CACHE_DEB"
    dpkg -i "$CACHE_DEB" || apt-get install -f -y
    cleanup_old_cached_debs "$CACHE_DEB"
else
    echo "Download failed"
    exit 1
fi
