# LocalSync
Sync your files between Windows and Android locally using Python Flask via HTTP

I mostly use this for syncing Geometry Dash data and more. The code is clean and easily maintainable...

* Precaution and notes!!
1. Public your network can hinder security issues!
2. While the app limits access to a all path in the server.py. Someone may be able exploit HTTP's security to mess with your files.
3. Rooting is not required.
4. Only util_receive_files.sh and util_send_files.sh can use root due to bugs (I can't solve this).

What's the requirements to use this app?
1. 2 or more devices running either Windows or Android
2. Some knowledge about shell scripts

How to use this?
1. Set-up packages and required softwares using the list below!
3. Download the repo and unzip it on 2 or more devices.
4. If it's Windows, run start.cmd. If it's Android, run start.sh.
5. Start run_server.sh on all devices. The session is now used to only host the HTTP server. Check the IP address of the devices you're going sync.
6. Run a new session of start.sh / start.cmd.
7. Run crud_database to add devices that you're going to interact with using the IP seen when running the server.
8. Go back and choose file_sync_operation and sync files there!
9. If there are features you want to change or add, tinker with the code yourself. It's pretty intuitive. Enjoy!
*Many weird cases has been accounted for but it's recommeded that you follow along properly...

How to set-up? 
For mobile
--------------------------------------------------------------------------------------
Apps required: Termux

#required

pkg update && pkg upgrade

pkg install iproute2

pkg install python

pip install flask

pip install requests

pkg install curl

pkg install jq

pkg install sqlite3

#for server killing scripts

pkg install lsof


For pc
--------------------------------------------------------------------------------------
Apps required: Msys64 UCRT64, Python, Windows Terminal

#required

pacman -Syu

pacman -S bc

pacman -S mingw-w64-ucrt-x86_64-python

pacman -S mingw-w64-ucrt-x86_64-python-pip

pacman -S mingw-w64-ucrt-x86_64-python-flask

pacman -S mingw-w64-ucrt-x86_64-python-requests

pacman -S mingw-w64-ucrt-x86_64-jq

pacman -S mingw-w64-ucrt-x86_64-sqlite3

#test connection
curl -v http://192.168.1.100:3000

#just in case, check ipv4

#termux

ifconfig

#msys

ipconfig

