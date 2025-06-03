#!/system/bin/sh
#tmux

export PATH="/c/msys64/usr/bin:$PATH"

TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
if [ -x "$TERMUX_BASH" ]; then
    BASH_CMD="su -c "$TERMUX_BASH""
else
    BASH_CMD="bash"
fi
ENVIRONMENT=$($BASH_CMD util_detect_env.sh)
echo $ENVIRONMENT

if [ "$ENVIRONMENT" = "termux" ]; then
    su -c "/data/data/com.termux/files/usr/bin/python server.py"
else
    /ucrt64/bin/python server.py
fi
