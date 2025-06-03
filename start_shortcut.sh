#!/bin/bash

#this is for the termux shortcutt
#place this in /data/data/com.termux/files/home/.shortcuts

android_path="/storage/self/primary/Vipxpert/Http"
windows_path="E:/Vipxpert"

path="$android_path"
if [ -x "$path" ]; then
cd "$path"
su -c "/data/data/com.termux/files/usr/bin/bash $path/start.sh"
else
path="$windows_path"
cd "$path"
su -c "bash $path/start.sh"
fi
