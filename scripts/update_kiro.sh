#!/bin/bash

set -e

# Use DEV_HOME so cache survives container recreation when only /home/dev is persisted.
DEV_HOME="${DEV_HOME:-/home/dev}"
if [ ! -d "$DEV_HOME" ]; then
    DEV_HOME="$HOME"
fi
CACHE_DIR="$DEV_HOME/.cache/auto_install/kiro"
mkdir -p "$CACHE_DIR"

get_kiro_installed_version() {
    dpkg-query -W -f='${Version}' kiro 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true
}

echo ">> Checking Kiro..."

INSTALLED_VER=$(get_kiro_installed_version)
METADATA_URL="https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json"
DOWNLOAD_URL=$(curl -fsSL --connect-timeout 10 --max-time 30 "$METADATA_URL" 2>/dev/null | jq -r '.releases[] | .updateTo.url | select(endswith(".tar.gz"))' | head -n 1 || true)
LATEST_VER=$(echo "$DOWNLOAD_URL" | grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | head -n 1 | tr -d '/' || true)

if [ -n "$INSTALLED_VER" ]; then
    if [ -z "$LATEST_VER" ]; then
        echo ">> Kiro installed ($INSTALLED_VER), but cannot fetch latest version. Skipping update."
        exit 0
    fi
    if [ "$INSTALLED_VER" == "$LATEST_VER" ]; then
        echo ">> Kiro is up to date ($INSTALLED_VER)."
        exit 0
    fi
    echo ">> Kiro update needed: $INSTALLED_VER -> $LATEST_VER"
else
    echo ">> Kiro not installed. Installing latest version${LATEST_VER:+: $LATEST_VER}..."
fi

if [ -z "$LATEST_VER" ]; then
    CACHED_DEB=$(ls -t "$CACHE_DIR"/kiro-*.deb 2>/dev/null | head -n 1 || true)
    if [ -n "$CACHED_DEB" ]; then
        echo ">> Latest version unknown, falling back to cached package: $CACHED_DEB"
        dpkg -i "$CACHED_DEB" || apt-get install -f -y
        echo ">> Kiro installation/update complete (from cache fallback)."
        exit 0
    fi
    echo "Error: Failed to fetch latest Kiro version and no cached package is available"
    exit 1
fi

SAFE_VER=$(echo "$LATEST_VER" | sed 's/[^A-Za-z0-9._-]/_/g')
CACHE_DEB="$CACHE_DIR/kiro-${SAFE_VER}.deb"

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
    aria2c -x 16 -s 16 -d "$CACHE_DIR" -o "$(basename "$CACHE_DEB")" "$DEB_URL"
fi

if [ ! -f "$CACHE_DEB" ]; then
    echo "Error: Download failed"
    exit 1
fi

echo ">> Installing Kiro..."
dpkg -i "$CACHE_DEB" || apt-get install -f -y

echo ">> Kiro installation/update complete."
