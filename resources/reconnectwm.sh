#!/bin/bash

# Execute scripts in /home/dev/.xrdp-reconnect/
if [ -d "/home/dev/.xrdp-reconnect" ]; then
    for script in /home/dev/.xrdp-reconnect/*; do
        if [ -x "$script" ]; then
            "$script"
        fi
    done
fi

sleep 3
xmodmap /etc/X11/Xmodmap.default
