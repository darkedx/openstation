#!/usr/bin/env bash

# Language setup based on SYSTEM_LANG environment variable
if [[ "${SYSTEM_LANG}" == *"zh"* ]] || [[ "${SYSTEM_LANG}" == *"CN"* ]]; then
    echo ">> Setting system language to Chinese (zh_CN.UTF-8)..."
    export LANG=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh
    export LC_ALL=zh_CN.UTF-8
else
    echo ">> Setting system language to English (en_US.UTF-8)..."
    export LANG=en_US.UTF-8
    export LANGUAGE=en_US:en
    export LC_ALL=en_US.UTF-8
fi

# Persist locale settings
echo "LANG=$LANG" > /etc/default/locale
echo "LANGUAGE=$LANGUAGE" >> /etc/default/locale
echo "LC_ALL=$LC_ALL" >> /etc/default/locale


# Check if user directory is empty (e.g. volume mounted) and restore from origin
if [ -d "/home/dev" ] && [ -z "$(ls -A /home/dev)" ]; then
    echo ">> Detected empty /home/dev, restoring from /home/.origin..."
    if [ -d "/home/.origin" ]; then
        cp -a /home/.origin/. /home/dev/
        # Ensure correct ownership
        chown -R dev:dev /home/dev
    else
        echo "Warning: /home/.origin not found, skipping restore."
    fi
fi


# Cleanup legacy NVM lines from .bashrc if they exist
if [ -f "/home/dev/.bashrc" ]; then
    echo ">> Cleaning up legacy NVM lines from .bashrc..."
    sed -i '\|export NVM_DIR="$HOME/.nvm"|d' /home/dev/.bashrc
    sed -i '\|\[ -s "$NVM_DIR/nvm.sh" \] && \\. "$NVM_DIR/nvm.sh"|d' /home/dev/.bashrc
    sed -i '\|\[ -s "$NVM_DIR/bash_completion" \] && \\. "$NVM_DIR/bash_completion"|d' /home/dev/.bashrc
fi

# Source shared base entry script
source /entry-base.sh
# Install/Update tools synchronously
sudo -i -u dev AUTO_INSTALL="$AUTO_INSTALL" bash -c '/usr/local/bin/install-tools.sh'


# Install packages from user directory
if [ -d "/home/dev/.openstation/packages" ]; then
    echo ">> Checking for packages in /home/dev/.openstation/packages..."
    # Check if there are any deb files
    if ls /home/dev/.openstation/packages/*.deb 1> /dev/null 2>&1; then
        echo "Installing found packages..."
        dpkg -i /home/dev/.openstation/packages/*.deb || apt-get install -f -y
    else
        echo "No .deb packages found."
    fi
fi

# Run sogou_fix.sh if /opt/sogoupinyin exists
if [ -d "/opt/sogoupinyin" ]; then
    echo ">> Running sogou_fix.sh..."
    /usr/local/bin/sogou_fix.sh
fi


# Configure xrdp (use DEV_USER env var to control user, RDP_PASSWORD to control password)
configure_xrdp



echo "Entrypoint: $@"

# If command is supervisord, or empty (default case, if CMD is cleared)
if [ "$1" == "/usr/bin/supervisord" ] || [ -z "$1" ]; then
    echo "Starting supervisord..."
    exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
else
    # If custom command, execute directly
    echo "Executing custom command: $@"
    exec "$@"
fi
