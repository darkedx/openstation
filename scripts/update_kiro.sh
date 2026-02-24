#!/bin/bash

set -e

# Helper functions
get_kiro_latest_version() {
    local metadata_url="https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json"
    curl -fsSL --connect-timeout 10 --max-time 30 "$metadata_url" 2>/dev/null | \
        jq -r '.releases[] | .updateTo.url | select(endswith(".tar.gz"))' | \
        grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | head -n 1 | tr -d '/'
}

get_kiro_installed_version() {
    dpkg-query -W -f='${Version}' kiro 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true
}

echo ">> Checking Kiro..."

INSTALLED_VER=$(get_kiro_installed_version)
LATEST_VER=$(get_kiro_latest_version)

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

# Prepare cache directory
CACHE_DIR="$HOME/.cache/auto_install/kiro"
mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"

# Download logic
METADATA_URL="https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json"
echo ">> Fetching metadata..."
METADATA_JSON=$(curl -fsSL "$METADATA_URL")

if [ -z "$METADATA_JSON" ]; then
    echo "Error: Failed to fetch Kiro metadata"
    exit 1
fi

DOWNLOAD_URL=$(echo "$METADATA_JSON" | jq -r '.releases[] | .updateTo.url | select(endswith(".tar.gz"))' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Error: Failed to find download URL"
    exit 1
fi

# Transform URL to DEB
# e.g. .../tar/kiro-0.1.0.tar.gz -> .../deb/kiro-0.1.0.deb
DEB_URL="${DOWNLOAD_URL//\/tar\//\/deb\/}"
DEB_URL="${DEB_URL//.tar.gz/.deb}"

echo ">> Downloading Kiro DEB from: $DEB_URL"

# Check if we already have this version cached?
# Since we name it 'latest.deb', we might want to be careful. 
# But the requirement is "keep the latest version package". 
# We'll just overwrite 'latest.deb' to ensure it matches the metadata we just fetched.

rm -f latest.deb
aria2c -x 16 -s 16 -o latest.deb "$DEB_URL"

if [ ! -f "latest.deb" ]; then
    echo "Error: Download failed"
    exit 1
fi

echo ">> Installing Kiro..."
# Use dpkg -i to install the local package directly to avoid re-downloading
dpkg -i ./latest.deb || apt-get install -f -y

echo ">> Kiro installation/update complete."
