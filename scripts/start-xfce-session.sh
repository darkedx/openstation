#!/bin/bash
if [ -f ~/.Xmodmap ]; then
    xmodmap ~/.Xmodmap
elif [ -f /etc/X11/Xmodmap.default ]; then
    xmodmap /etc/X11/Xmodmap.default
fi


# Source .bashrc to ensure environment variables are available in XFCE
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi


# Start desktop manager
exec startxfce4
