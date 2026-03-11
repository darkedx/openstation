#!/bin/bash

set -e

# Use DEV_HOME so cache survives container recreation when only /home/dev is persisted.
DEV_HOME="${DEV_HOME:-/home/dev}"
if [ ! -d "$DEV_HOME" ]; then
    DEV_HOME="$HOME"
fi

CACHE_DIR="$DEV_HOME/.cache/auto_install/antigravity"
mkdir -p "$CACHE_DIR"

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

if [ "$INSTALLED_VER" == "$LATEST_VER" ]; then
    echo "Antigravity is up to date ($INSTALLED_VER)"
    exit 0
fi

echo "Updating Antigravity: ${INSTALLED_VER:-none} -> $LATEST_VER"

SAFE_VER=$(echo "$LATEST_VER" | sed 's/[^A-Za-z0-9._-]/_/g')
CACHE_DEB="$CACHE_DIR/antigravity-${SAFE_VER}.deb"

if [ -f "$CACHE_DEB" ]; then
    echo "Using cached package: $CACHE_DEB"
else
    echo "Downloading Antigravity DEB..."
    DEB_URL=$(apt-get install --reinstall --print-uris antigravity | grep -oE "https?://[^']+" | head -n 1)

    if [ -n "$DEB_URL" ]; then
        echo ">> Downloading from: $DEB_URL"
        aria2c -x 16 -s 16 -d "$CACHE_DIR" -o "$(basename "$CACHE_DEB")" "$DEB_URL"
    else
        echo "Warning: Could not get URL from apt-get, falling back to apt-get download"
        cd "$CACHE_DIR"
        apt-get download antigravity
        DOWNLOADED_DEB=$(ls -t antigravity_*.deb 2>/dev/null | head -n 1 || true)
        if [ -n "$DOWNLOADED_DEB" ]; then
            mv "$DOWNLOADED_DEB" "$CACHE_DEB"
        fi
    fi
fi

if [ -f "$CACHE_DEB" ]; then
    echo "Installing from cache: $CACHE_DEB"
    dpkg -i "$CACHE_DEB" || apt-get install -f -y
else
    echo "Download failed"
    exit 1
fi
