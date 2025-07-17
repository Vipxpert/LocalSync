#!/data/data/com.termux/files/usr/bin/bash

LOCAL_IP=$(ipconfig | grep -E "IPv4|IPv4 Address" | awk -F: '{print $2}' | sed 's/^[ \t]*//;s/\r$//' | head -n1)
SUBNET=$(echo $LOCAL_IP | cut -d'.' -f1-3).0/24
nmap -p 3000 $SUBNET --open | grep "Nmap scan report" | awk '{print "Flask server at " $5}'

echo 'export PATH="$PATH:/c/Program Files (x86)/Nmap"' >>~/.bash_profile
source ~/.bash_profile
