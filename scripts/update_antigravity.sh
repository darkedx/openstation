#!/bin/bash

set -e

# Update apt cache
apt-get update

# Get versions
INSTALLED_VER=""
if command -v antigravity >/dev/null 2>&1; then
    INSTALLED_VER=$(dpkg-query -W -f='${Version}' antigravity 2>/dev/null)
fi

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

CACHE_DIR="$HOME/.cache/auto_install/antigravity"
mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"

rm -f *.deb
echo "Downloading Antigravity DEB..."
DEB_URL=$(apt-get install --reinstall --print-uris antigravity | grep -oE "https?://[^']+" | head -n 1)

if [ -n "$DEB_URL" ]; then
    echo ">> Downloading from: $DEB_URL"
    aria2c -x 16 -s 16 -o latest.deb "$DEB_URL"
else
    echo "Warning: Could not get URL from apt-get, falling back to apt-get download"
    apt-get download antigravity
    mv *.deb latest.deb
fi

if [ -f "latest.deb" ]; then
    echo "Installing from latest.deb..."
    dpkg -i ./latest.deb || apt-get install -f -y
else
    echo "Download failed"
    exit 1
fi
