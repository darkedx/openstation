#!/usr/bin/env bash

set -e

[ "$DEBUG" == 'true' ] && set -x

# Global variables
DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"

DAEMON=sshd

mkdir -p /var/run/sshd

echo "> Starting SSHD"

# Copy default config from cache, if required
if [ ! "$(ls -A /etc/ssh)" ]; then
    cp -a /etc/ssh.cache/* /etc/ssh/
fi

set_hostkeys() {
    printf '%s\n' \
        'set /files/etc/ssh/sshd_config/HostKey[1] /etc/ssh/keys/ssh_host_rsa_key' \
        'set /files/etc/ssh/sshd_config/HostKey[2] /etc/ssh/keys/ssh_host_ecdsa_key' \
        'set /files/etc/ssh/sshd_config/HostKey[3] /etc/ssh/keys/ssh_host_ed25519_key' \
    | augtool -s 1> /dev/null
}

print_fingerprints() {
    local BASE_DIR=${1-'/etc/ssh'}
    for item in rsa ecdsa ed25519; do
        echo ">>> Host key ${item} fingerprint"
        ssh-keygen -E md5 -lf ${BASE_DIR}/ssh_host_${item}_key
        ssh-keygen -E sha256 -lf ${BASE_DIR}/ssh_host_${item}_key
        ssh-keygen -E sha512 -lf ${BASE_DIR}/ssh_host_${item}_key
    done
}

check_authorized_key_ownership() {
    local file="$1"
    local _uid="$2"
    local _gid="$3"
    local uid_found="$(stat -c %u ${file})"
    local gid_found="$(stat -c %g ${file})"

    if ! ( [[ ( "$uid_found" == "$_uid" ) && ( "$gid_found" == "$_gid" ) ]] || [[ ( "$uid_found" == "0" ) && ( "$gid_found" == "0" ) ]] ); then
        echo "Warning: Incorrect ownership of file ${file}. Expected uid/gid: ${_uid}/${_GID}, but found: ${uid_found}/${gid_found}. File uid/gid must match SSH_USERS or be owned by root."
    fi
}

# Generate Host keys, if required
if ls /etc/ssh/keys/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys found in key directory"
    set_hostkeys
    print_fingerprints /etc/ssh/keys
elif ls /etc/ssh/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys found in default location"
    # Don't do anything
    print_fingerprints
else
    echo ">> Generating new host keys"
    mkdir -p /etc/ssh/keys
    ssh-keygen -A
    mv /etc/ssh/ssh_host_* /etc/ssh/keys/
    set_hostkeys
    print_fingerprints /etc/ssh/keys
fi

# Fix permissions, if writable.
# NB ownership of /etc/authorized_keys are not changed
if [ -w ~/.ssh ]; then
    chown root:root ~/.ssh && chmod 700 ~/.ssh/
fi
if [ -w ~/.ssh/authorized_keys ]; then
    chown root:root ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
if [ -w /etc/authorized_keys ]; then
    chown root:root /etc/authorized_keys
    chmod 755 /etc/authorized_keys
    # test for writability before attempting chmod
    for f in $(find /etc/authorized_keys/ -maxdepth 1 -type f); do
        [ -w "${f}" ] && chmod 644 "${f}"
    done
fi

# Add groups if SSH_GROUPS=group:gid set
if [ -n "${SSH_GROUPS}" ]; then
    GROUPZ=$(echo $SSH_GROUPS | tr "," "\n")
    for G in $GROUPZ; do
        IFS=':' read -ra GA <<< "$G"
        _NAME=${GA[0]}
        _GID=${GA[1]}
        echo ">> Adding group ${_NAME}, gid: ${_GID}."
        getent group ${_NAME} >/dev/null 2>&1 || groupadd -g ${_GID} ${_NAME}
    done
fi

# Add users if SSH_USERS=user:uid:gid set
if [ -n "${SSH_USERS}" ]; then
    USERS=$(echo $SSH_USERS | tr "," "\n")
    for U in $USERS; do
        IFS=':' read -ra UA <<< "$U"
        _NAME=${UA[0]}
        _UID=${UA[1]}
        _GID=${UA[2]}
        if [ ${#UA[*]} -ge 4 ]; then
            _SHELL=${UA[3]}
        else
            _SHELL=''
        fi

        echo ">> Adding user ${_NAME}, uid: ${_UID}, gid: ${_GID}, shell: ${_SHELL:-<default>}."
        if [ ! -e "/etc/authorized_keys/${_NAME}" ]; then
            echo "Warning: SSH authorized_keys not found for user ${_NAME}!"
        else
            check_authorized_key_ownership /etc/authorized_keys/${_NAME} ${_UID} ${_GID}
        fi
        if [ -z "${SSH_GROUPS}" ]; then
            getent group ${_NAME} >/dev/null 2>&1 || groupadd -g ${_GID} ${_NAME}
        fi
        getent passwd ${_NAME} >/dev/null 2>&1 || useradd -r -m -p '' -u ${_UID} -g ${_GID} -s ${_SHELL:-""} -c 'SSHD User' ${_NAME}
    done
else
    # Warn if no authorized_keys
    if [ ! -e ~/.ssh/authorized_keys ] && [ ! "$(ls -A /etc/authorized_keys)" ]; then
        echo "Warning: SSH authorized_keys not found!"
    fi
fi

# Add root keys if SSH_ROOT_KEY_xxx is set
if printenv | grep -q '^SSH_ROOT_KEY_'; then
    echo ">> Found SSH_ROOT_KEY env vars, adding them to /root/.ssh/authorized_keys and ${DEV_HOME}/.ssh/authorized_keys"
    
    # Root user
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    chown root:root /root/.ssh
    printenv | grep '^SSH_ROOT_KEY_' | cut -d'=' -f2- > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys

    # Dev user
    mkdir -p ${DEV_HOME}/.ssh
    chmod 700 ${DEV_HOME}/.ssh
    chown ${DEV_USER}:${DEV_USER} ${DEV_HOME}/.ssh
    printenv | grep '^SSH_ROOT_KEY_' | cut -d'=' -f2- > ${DEV_HOME}/.ssh/authorized_keys
    chmod 600 ${DEV_HOME}/.ssh/authorized_keys
    chown -R ${DEV_USER}:${DEV_USER} ${DEV_HOME}/.ssh
fi

# Unlock root account, if enabled
if [[ "${SSH_ENABLE_ROOT}" == "true" ]]; then
    usermod -p '' root
else
    echo "Info: root account is now locked. Set SSH_ENABLE_ROOT to unlock account."
fi

# Update MOTD
if [ -v MOTD ]; then
    echo -e "$MOTD" > /etc/motd
fi

# PasswordAuthentication (disabled by default)
if [[ "${SSH_ENABLE_PASSWORD_AUTH}" == "true" ]] || [[ "${SSH_ENABLE_ROOT_PASSWORD_AUTH}" == "true" ]]; then
    echo 'set /files/etc/ssh/sshd_config/PasswordAuthentication yes' | augtool -s 1> /dev/null
    echo "Warning: Password authentication enabled."

    # Root Password Authentification
    if [[ "${SSH_ENABLE_ROOT_PASSWORD_AUTH}" == "true" ]]; then
        echo 'set /files/etc/ssh/sshd_config/PermitRootLogin yes' | augtool -s 1> /dev/null
        echo "Warning: Password authentication enabled for root user."
    else
        echo "Info: Password authentication not enabled for root user. Set SSH_ENABLE_ROOT_PASSWORD_AUTH=true to enable."
    fi

else
    echo 'set /files/etc/ssh/sshd_config/PasswordAuthentication no' | augtool -s 1> /dev/null
fi

configure_sftp_only_mode() {
    echo "Info: Configuring SFTP only mode"
    : ${SFTP_CHROOT:='/data'}
    chown 0:0 ${SFTP_CHROOT}
    chmod 755 ${SFTP_CHROOT}
    printf '%s\n' \
        'set /files/etc/ssh/sshd_config/Subsystem/sftp "internal-sftp"' \
        'set /files/etc/ssh/sshd_config/AllowTCPForwarding no' \
        'set /files/etc/ssh/sshd_config/GatewayPorts no' \
        'set /files/etc/ssh/sshd_config/X11Forwarding no' \
        'set /files/etc/ssh/sshd_config/ForceCommand internal-sftp' \
        "set /files/etc/ssh/sshd_config/ChrootDirectory ${SFTP_CHROOT}" \
    | augtool -s 1> /dev/null
}

configure_scp_only_mode() {
    echo "Info: Configuring SCP only mode"
    USERS=$(echo $SSH_USERS | tr "," "\n")
    for U in $USERS; do
        _NAME=$(echo "${U}" | cut -d: -f1)
        usermod -s '/usr/bin/rssh' ${_NAME}
    done
    (grep '^[a-zA-Z]' /etc/rssh.conf.default; echo "allowscp") > /etc/rssh.conf
}

configure_rsync_only_mode() {
    echo "Info: Configuring rsync only mode"
    USERS=$(echo $SSH_USERS | tr "," "\n")
    for U in $USERS; do
        _NAME=$(echo "${U}" | cut -d: -f1)
        usermod -s '/usr/bin/rssh' ${_NAME}
    done
    (grep '^[a-zA-Z]' /etc/rssh.conf.default; echo "allowrsync") > /etc/rssh.conf
}

configure_ssh_options() {
    # Enable AllowTcpForwarding
    if [[ "${TCP_FORWARDING}" == "true" ]]; then
        echo 'set /files/etc/ssh/sshd_config/AllowTcpForwarding yes' | augtool -s 1> /dev/null
    fi
    # Enable GatewayPorts
    if [[ "${GATEWAY_PORTS}" == "true" ]]; then
        echo 'set /files/etc/ssh/sshd_config/GatewayPorts yes' | augtool -s 1> /dev/null
    fi
    # Disable SFTP
    if [[ "${DISABLE_SFTP}" == "true" ]]; then
        printf '%s\n' \
            'rm /files/etc/ssh/sshd_config/Subsystem/sftp' \
            'rm /files/etc/ssh/sshd_config/Subsystem' \
        | augtool -s 1> /dev/null
    fi
}

# Configure mutually exclusive modes
if [[ "${SFTP_MODE}" == "true" ]]; then
    configure_sftp_only_mode
elif [[ "${SCP_MODE}" == "true" ]]; then
    configure_scp_only_mode
elif [[ "${RSYNC_MODE}" == "true" ]]; then
    configure_rsync_only_mode
else
    configure_ssh_options
fi

# Run scripts in /etc/entrypoint.d
for f in /etc/entrypoint.d/*; do
    if [[ -x ${f} ]]; then
        echo ">> Running: ${f}"
        ${f}
    fi
done

# <BASHRC_HELPER>
ensure_bashrc_exists() {
    local TARGET_USER="${1:-${DEV_USER}}"
    local TARGET_HOME="/home/${TARGET_USER}"
    local BASHRC_FILE="${TARGET_HOME}/.bashrc"

    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        return
    fi

    if [ ! -f "$BASHRC_FILE" ]; then
        echo ">> Creating .bashrc file for ${TARGET_USER}"
        if [ -f "/etc/skel/.bashrc" ]; then
            cp /etc/skel/.bashrc "$BASHRC_FILE"
        else
            cat > "$BASHRC_FILE" <<EOF
# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

# User specific environment
if ! [[ "\$PATH" =~ "\$HOME/.local/bin:\$HOME/bin:" ]]
then
    PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"
fi
export PATH

# User specific aliases and functions
EOF
        fi
        chown ${TARGET_USER}:${TARGET_USER} "$BASHRC_FILE"
    fi
}
# </BASHRC_HELPER>

if [ -d "${DEV_HOME}/.npm" ]; then
    if [ "$(stat -c %U ${DEV_HOME}/.npm)" != "${DEV_USER}" ]; then
        echo ">> Changing ownership of ${DEV_HOME}/.npm to ${DEV_USER}"
        chown -R ${DEV_USER}:${DEV_USER} ${DEV_HOME}/.npm
    fi
fi


# <RDP>
# xrdp startup function
# Environment variables:
#   RDP_PASSWORD - RDP user password (optional, if not set uses default or auto-generated)
#   DEV_USER     - Username to use (optional, defaults to root)
configure_xrdp() {
    echo "> Configuring xrdp service"

    # User config - defaults to dev user
    RDP_USER="${DEV_USER}"
    RDP_HOME="${DEV_HOME}"

    # XRDP certificate configuration
    CERT_DIR="${RDP_HOME}/.xrdp/cert"
    CERT_FILE="${CERT_DIR}/cert.pem"
    KEY_FILE="${CERT_DIR}/key.pem"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo ">> Generating XRDP certificate (valid for 100 years)..."
        mkdir -p "$CERT_DIR"
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -out "$CERT_FILE" -days 36500 -subj "/CN=localhost"
        chown -R ${RDP_USER}:${RDP_USER} "${RDP_HOME}/.xrdp"
        chmod 600 "$KEY_FILE"
    else
        echo ">> Using existing XRDP certificate"
    fi

    echo ">> Updating xrdp.ini config to use custom certificate..."
    if [ -f /etc/xrdp/xrdp.ini ]; then
        sed -i "s|^certificate=.*|certificate=${CERT_FILE}|" /etc/xrdp/xrdp.ini
        sed -i "s|^key_file=.*|key_file=${KEY_FILE}|" /etc/xrdp/xrdp.ini
    fi

    # Set user password
    if [ -n "${RDP_PASSWORD}" ]; then
        echo ">> Setting password for user ${RDP_USER}"
        echo "${RDP_USER}:${RDP_PASSWORD}" | chpasswd
    else
        # Generate random password
        RDP_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
        echo ">> RDP_PASSWORD not set, generated random password"
        echo "${RDP_USER}:${RDP_PASSWORD}" | chpasswd
    fi
    
    # Fix permissions
    mkdir -p ${RDP_HOME}/.config
    chown -R ${RDP_USER}:${RDP_USER} ${RDP_HOME}/.config
    echo "run_im fcitx" > ${RDP_HOME}/.xinputrc
    chown ${RDP_USER}:${RDP_USER} ${RDP_HOME}/.xinputrc

    # Add fcitx env vars to dev user .bashrc (if not already added)
    local BASHRC_FILE="${RDP_HOME}/.bashrc"


    # Ensure .bashrc exists again (although ensure_bashrc_exists ran before, RDP_USER might not be dev)
    ensure_bashrc_exists "${RDP_USER}"

    if ! grep -q "source /usr/local/bin/init-fcitx.sh" "$BASHRC_FILE"; then
        echo ">> Adding fcitx env vars to ${DEV_USER} .bashrc"
        echo "source /usr/local/bin/init-fcitx.sh" >> "$BASHRC_FILE"
    fi

    # Add fcitx env vars to dev user .xprofile
    XPROFILE="${DEV_HOME}/.xprofile"
    if [ ! -f "$XPROFILE" ]; then
        touch "$XPROFILE"
        chown ${DEV_USER}:${DEV_USER} "$XPROFILE"
    fi

    if ! grep -q "source /usr/local/bin/init-fcitx.sh" "$XPROFILE"; then
         echo ">> Adding fcitx env vars to ${DEV_USER} .xprofile"
         echo "source /usr/local/bin/init-fcitx.sh" >> "$XPROFILE"
    fi


    # Set xfce4-terminal as default terminal
    if command -v update-alternatives >/dev/null 2>&1; then
        echo ">> Setting default x-terminal-emulator to xfce4-terminal"
        update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper || true
    fi

    # Configure xfce4-terminal encoding
    # Ensure directory exists
    TERMINAL_CONFIG_DIR="${RDP_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
    if [ ! -d "$TERMINAL_CONFIG_DIR" ]; then
        echo ">> Creating xfce4-terminal config directory: $TERMINAL_CONFIG_DIR"
        mkdir -p "$TERMINAL_CONFIG_DIR"
        chown -R ${RDP_USER}:${RDP_USER} "${RDP_HOME}/.config"
    fi

    # Write config file
    TERMINAL_CONFIG_FILE="${TERMINAL_CONFIG_DIR}/xfce4-terminal.xml"
    if [ ! -f "$TERMINAL_CONFIG_FILE" ]; then
        echo ">> Creating xfce4-terminal config file: $TERMINAL_CONFIG_FILE"
        cat > "$TERMINAL_CONFIG_FILE" <<EOF
<?xml version="1.1" encoding="UTF-8"?>

<channel name="xfce4-terminal" version="1.0">
  <property name="encoding" type="string" value="UTF-8"/>
</channel>
EOF
        chown ${RDP_USER}:${RDP_USER} "$TERMINAL_CONFIG_FILE"
    fi

    # Configure .Xmodmap (if not exists, create symlink to system default)
    if [ ! -e "${RDP_HOME}/.Xmodmap" ] && [ -f "/etc/X11/Xmodmap.default" ]; then
        echo ">> Creating .Xmodmap symlink"
        ln -s /etc/X11/Xmodmap.default "${RDP_HOME}/.Xmodmap"
        chown -h ${RDP_USER}:${RDP_USER} "${RDP_HOME}/.Xmodmap"
    fi

    # Configure xsession file to start XFCE
    if [ ! -f ${RDP_HOME}/.xsession ]; then
        echo ">> Creating .xsession file"
        cat > ${RDP_HOME}/.xsession <<'EOF'
#!/bin/bash
exec /usr/local/bin/start-xfce-session.sh
EOF
        chmod +x ${RDP_HOME}/.xsession
        chown ${RDP_USER}:${RDP_USER} ${RDP_HOME}/.xsession
    fi

    # Clean up potentially stale PID files and processes
    echo ">> Cleaning up xrdp environment..."
    rm -rf /var/run/xrdp-sesman.pid
    rm -rf /var/run/xrdp.pid
    rm -rf /var/run/xrdp/xrdp-sesman.pid
    rm -rf /var/run/xrdp/xrdp.pid
    pkill -9 xrdp-sesman 2>/dev/null || true
    pkill -9 xrdp 2>/dev/null || true
    sleep 1

    # Ensure run directory exists
    mkdir -p /var/run/xrdp
}
# </RDP>

# Export variables and functions for sub-scripts
export DAEMON
export -f set_hostkeys
export -f print_fingerprints
export -f check_authorized_key_ownership
export -f configure_sftp_only_mode
export -f configure_scp_only_mode
export -f configure_rsync_only_mode
export -f configure_ssh_options