[中文](./README_CN.md)

# 💡 Motivation

As a developer who heavily relies on AI for coding, I often encounter frustrating situations: Claude Code/Antigravity/... is running a critical and time-consuming task on my MacBook, but I have to close the lid to go for lunch or commute. Boom—the task is interrupted.

I developed **OpenStation** to solve this pain point. I wanted a tireless, always-online containerized workspace that keeps my development workflow running 24/7, completely unaffected by the state of my local hardware.

Through RDP, you can seamlessly connect to your fully equipped workspace from any device—iPhone, iPad, or Android. Whether you are buying coffee, taking a train, or even **sitting on the toilet**, you can easily connect, check the AI's progress, and dispatch new tasks at any time.

# Quick Start
```yaml
services:
  openstation:
    image: ghcr.io/darkedx/openstation:latest
    privileged: true
    restart: always
    shm_size: '1gb' # Shared memory required for Chrome browsing
    ulimits: # Relax file descriptor and message queue limits to avoid issues with Sogou Input Method when running multiple OpenStation instances on the same host
      nofile:
        soft: 65536
        hard: 65536
      msgqueue:
        soft: 8192000
        hard: 8192000
    # Optional, assign NVIDIA GPU to the container (OpenStation has NVIDIA drivers installed)
    # runtime: nvidia 
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - capabilities: [gpu]
    environment:
      AUTO_INSTALL: claude,gemini,antigravity,fvm,kiro,opencode,codex # Tools and software to auto-install, check AUTO_INSTALL variable introduction for all available values
      SSH_ROOT_KEY_DEFAULT: "ssh-ed25519 AAAxxxxxxxx..." # Your SSH public key
      RDP_PASSWORD: 123456 # Your RDP password
      SYSTEM_LANG: en_US # or zh_CN
    ports:
      - "2222:22" # SSH port mapping
      - "33389:3389" # RDP port mapping
    volumes:
      - ./data/ssh:/etc/ssh # Persist SSH host keys
      - ./home:/home/dev # Persist user directory


```

# Pre-installed Tools

OpenStation is built on **Debian 13** and comes pre-installed with a comprehensive set of development tools:

## Desktop & Environment
- **XFCE4**: Lightweight desktop environment
- **XRDP**: RDP server, supports all RDP clients
- **Input Method**: Fcitx + Sogou Pinyin (Requires manual download of Sogou Input Method installer to ~/.openstation/packages/, will be automatically installed and configured after container restart)
- **Browser**: Google Chrome

## Languages (Managed by [mise](https://mise.jdx.dev))
- **Node.js**
- **Python**
- **Go**
- **Java**
- **Rust**

## Core Tools
- **Package Managers**: `apt`, `mise`, `homebrew`
- **Editors & Shell**: `vim`, `tmux`, `bash`
- **Development Tools**: `git`, `docker` (Docker-in-Docker), `build-essential`, `cmake`, `clang`, `ninja`
- **CLI Enhanced Tools**: `curl`, `wget`, `jq`, `yq`, `ripgrep (rg)`, `bat`, `eza`, `btop`, `aria2`
- **Database Clients**: `psql`, `mysql`, `redis-cli`
- **System Tools**: `supervisor`, `kopia` (backup), `openssh-server`

# I also wrote some useful scripts

gita: git worktree management tool, convenient for developing multiple features for a project simultaneously

xrdpmode: Switch RDP settings between RFX and 264 modes, requires reconnection to take effect

# Environment Variables

OpenStation supports automatic installation/update of tools at startup via the `AUTO_INSTALL` environment variable.

## AUTO_INSTALL

Specifies the tools to install or update when the container starts, multiple tools separated by commas.

Supported values include:
- `gemini`: Google Gemini CLI
- `claude`: Claude Code
- `antigravity`: Antigravity - Google's AI IDE
- `kiro`: Kiro - AWS AI IDE
- `fvm`: Flutter Version Management Tool
- `opencode`: OpenCode AI Coding Assistant
- `openclaw`: OpenClaw Gateway
- `codex`: OpenAI Codex CLI
