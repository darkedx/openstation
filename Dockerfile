FROM docker:28.3-dind as docker
FROM debian:13


ENV SUDO_GROUP=sudo DOCKER_GROUP=docker DOCKER_TLS_CERTDIR=/certs

RUN apt update && apt install gpg curl sudo -y && mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg | \
    gpg --dearmor --yes -o /etc/apt/keyrings/antigravity-repo-key.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/antigravity-repo-key.gpg] https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev/ antigravity-debian main" | \
    tee /etc/apt/sources.list.d/antigravity.list > /dev/null && \
\
    curl -s https://kopia.io/signing-key | sudo gpg --dearmor -o /etc/apt/keyrings/kopia-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" | sudo tee /etc/apt/sources.list.d/kopia.list \
\
    && curl -sSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google.list \
\
    && echo "deb http://deb.debian.org/debian experimental main" | sudo tee /etc/apt/sources.list.d/experimental.list \
\
    && curl -fSs https://mise.jdx.dev/gpg-key.pub | sudo gpg --dearmor -o /etc/apt/keyrings/mise-archive-keyring.pub \
    && echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.pub arch=amd64] https://mise.jdx.dev/deb stable main" | sudo tee /etc/apt/sources.list.d/mise.list \
\
    && apt-get update && \
    apt-get install -y \
    sudo bash openssl ca-certificates \
    iptables net-tools \
    pigz xz-utils unzip p7zip-full \
    curl wget btop vim jq \
    git coreutils findutils libc6 cmake make g++ gcc linux-headers-generic augeas-tools cron \
    tmux openssh-server rsync supervisor kopia \
    mise aria2 \
\
    locales \
    fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-jetbrains-mono \
    xvfb xauth dbus-x11 xterm psmisc \
    x11-xserver-utils x11-utils \
    xfce4 xfce4-terminal thunar mousepad \
    xfce4-notifyd xfce4-taskmanager \
    libgtk-3-bin libpulse0 \
\
    xfce4-battery-plugin \
    xfce4-clipman-plugin \
    xfce4-cpufreq-plugin \
    xfce4-cpugraph-plugin \
    xfce4-diskperf-plugin \
    xfce4-datetime-plugin \
    xfce4-fsguard-plugin \
    xfce4-genmon-plugin \
    xfce4-netload-plugin \
    xfce4-places-plugin \
    xfce4-sensors-plugin \
    xfce4-systemload-plugin \
    xfce4-timer-plugin \
    xfce4-verve-plugin \
    xfce4-weather-plugin \
    xfce4-whiskermenu-plugin \
    x11-xserver-utils \
\
    adwaita-icon-theme papirus-icon-theme arc-theme \
    wget sudo curl gpg git bzip2 vim procps iproute2 \
    libnss3 libnspr4 libasound2 libgbm1 ca-certificates fonts-liberation xdg-utils \
    libayatana-appindicator3-1 \
    libxv1 mesa-utils mesa-utils-extra \
\
    apt-transport-https \
    ca-certificates \
    curl \
    rclone \ 
    eza bat ripgrep \
    gnupg \
    fonts-symbola google-chrome-stable \
    protobuf-compiler \
    ninja-build \
    build-essential \
    clang \
    cmake \
    pkg-config \
\
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libjavascriptcoregtk-4.1-dev \
    libsoup-3.0-dev \
\
    zenity \
    xdg-desktop-portal-gtk \
\
    postgresql-client \
    mariadb-client \
    redis-tools \
\
    && \
    apt-get install -t experimental xorgxrdp xorg xclip -y && \
    sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen && \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && \
    locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq

SHELL ["bash", "-c"]

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy
RUN update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

RUN groupadd -r ${DOCKER_GROUP}

COPY --from=docker /usr/local/bin/ /usr/local/bin/
COPY --from=docker /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/


VOLUME /var/lib/docker

# <RDP>

# ENVIRONMENT VARIABLES
ENV DEBIAN_FRONTEND=noninteractive \
    SYSTEM_LANG=en_US \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TERM=xterm


# Configure xrdp to use XFCE
RUN echo "startxfce4" > /etc/skel/.xsession && \
    chmod +x /etc/skel/.xsession && \
    sed -i 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config


# Manually build xrdp
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources && \
    rm -f /etc/apt/sources.list.d/google.list && \
    apt-get update && \
    cd /tmp && \
    XRDP_VERSION=0.10.4.1 && \
    XRDP_SRC_DIR=/tmp/xrdp && \
    wget https://github.com/neutrinolabs/xrdp/releases/download/v${XRDP_VERSION}/xrdp-${XRDP_VERSION}.tar.gz && \
    tar xvzf xrdp-${XRDP_VERSION}.tar.gz && \
    mv xrdp-${XRDP_VERSION} "${XRDP_SRC_DIR}" && \
    cd "${XRDP_SRC_DIR}" && \
    wget https://raw.githubusercontent.com/neutrinolabs/xrdp/refs/tags/v${XRDP_VERSION}/scripts/install_xrdp_build_dependencies_with_apt.sh && \
    chmod +x install_xrdp_build_dependencies_with_apt.sh && \
    sed -i 's/apt-get upgrade/apt-get upgrade -y/g' install_xrdp_build_dependencies_with_apt.sh && \
    ./install_xrdp_build_dependencies_with_apt.sh max && \
    ./bootstrap && \
    ./configure --enable-ibus --enable-ipv6 --enable-jpeg --enable-fuse --enable-mp3lame \
    --enable-fdkaac --enable-opus --enable-rfxcodec --enable-painter \
    --enable-pixman --enable-utmp -with-imlib2 --with-freetype2 \
    --enable-tests --enable-x264 --enable-openh264 --enable-vsock && \
    make && \
    make install && \
    ln -s /usr/local/sbin/xrdp{,-sesman} /usr/sbin && \
    apt-get install -y nvidia-driver nvidia-kernel-dkms && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /tmp/*

COPY resources/reconnectwm.sh /etc/xrdp/reconnectwm.sh
RUN chmod +x /etc/xrdp/reconnectwm.sh

# Input Method
RUN apt-get update && \
    # Remove existing input methods
    apt-get remove -y sogoupinyin || true && \
    apt-get purge -y fcitx5* fcitx5-pinyin fcitx5-table || true && \
    apt-get remove -y fcitx fcitx-bin fcitx-data || true && \
    apt-get remove -y ibus || true && \
    apt-get autoremove -y && \
    # Install fcitx framework
    apt-get install -y fcitx && \
    # Install remaining dependencies
    apt-get install -y \
    libqt5qml5 libqt5quick5 libqt5quickwidgets5 qml-module-qtquick2 \
    libgsettings-qt1 && \
    # Clean up
    rm -rf /var/lib/apt/lists/*

# Create dev user (uid 1000), passwordless, supports sudo without password
RUN set -xe \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -G ${SUDO_GROUP},${DOCKER_GROUP} -s /bin/bash dev \
    && passwd -d dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && cp /etc/skel/.xsession /home/dev/.xsession \
    && chown dev:dev /home/dev/.xsession \
    && mv /home/dev /home/.origin \
    && ln -s /home/.origin /home/dev

# </RDP>

# <DEV_ENV>

USER root
WORKDIR /home/dev


# Configure mise for dev user
USER dev
COPY resources/mise-config.toml /etc/mise/config.toml
COPY resources/claude.json /usr/local/share/claude-default.json
RUN \
    # Initialize mise in .bashrc
    echo 'eval "$(mise activate bash)"' >> /home/dev/.bashrc && \
    # Install tools
    mise install
ENV NONINTERACTIVE=1

RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"' >> /home/dev/.bashrc

# Switch back to root
USER root

ENV PATH="/home/dev/.local/share/mise/shims:$PATH"

# </DEV_ENV>

# <SSH>
COPY scripts/dev-entry-base.sh /entry-base.sh
RUN chmod +x /entry-base.sh

COPY scripts/dev-entry.sh /entry.sh

RUN chmod +x /entry.sh && \
    mkdir -p /home/dev/.ssh /etc/authorized_keys && chmod 700 /home/dev/.ssh/ && \
    chown -R dev:dev /home/dev/.ssh && \
    augtool 'set /files/etc/ssh/sshd_config/AuthorizedKeysFile ".ssh/authorized_keys /etc/authorized_keys/%u"' && \
    echo -e "Port 22\n" >> /etc/ssh/sshd_config && \
    cp -a /etc/ssh /etc/ssh.cache && \
    mkdir -p /home/dev/src && chown dev:dev /home/dev/src

RUN locale-gen zh_CN.UTF-8 en_US.UTF-8 && update-locale LANG=en_US.UTF-8

EXPOSE 22

ENV SSH_ENABLE_ROOT=true
ENV TCP_FORWARDING=true
ENV DEV_USER=dev
ENV DEV_UID=1000
ENV DEV_GID=1000

# Remove build-time symlink and create mount point
RUN rm /home/dev && \
    mkdir -p /home/dev && \
    chown dev:dev /home/dev

ENTRYPOINT ["/entry.sh"]

# /etc/ssh/keys/  SSH host keys
# /home/dev/      User directory, for persistent application configuration
# </SSH>

COPY resources/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY scripts/update_antigravity.sh /update_antigravity.sh
COPY scripts/update_kiro.sh /update_kiro.sh
COPY scripts/update_ai_tools.sh /update_ai_tools.sh

COPY scripts/sogou_fix.sh /usr/local/bin/sogou_fix.sh
COPY scripts/init-fcitx.sh /usr/local/bin/init-fcitx.sh
COPY scripts/start-xfce-session.sh /usr/local/bin/start-xfce-session.sh
COPY scripts/xrdpmode /usr/local/bin/xrdpmode
COPY scripts/gita /usr/local/bin/gita
COPY scripts/install-tools.sh /usr/local/bin/install-tools.sh
COPY resources/Xmodmap /etc/X11/Xmodmap.default
RUN mv /usr/share/glvnd/egl_vendor.d/10_nvidia.json /usr/share/glvnd/egl_vendor.d/10_nvidia.json.bak
RUN chmod +x /usr/local/bin/start-xfce-session.sh /usr/local/bin/xrdpmode /usr/local/bin/gita /usr/local/bin/install-tools.sh /usr/local/bin/sogou_fix.sh

# Configure Docker daemon
RUN mkdir -p /etc/docker && \
    if [ ! -f /etc/docker/daemon.json ]; then echo "{}" > /etc/docker/daemon.json; fi && \
    jq '. + {"iptables": false, "userland-proxy": true}' /etc/docker/daemon.json > /tmp/daemon.json && \
    mv /tmp/daemon.json /etc/docker/daemon.json

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# </SSH>
