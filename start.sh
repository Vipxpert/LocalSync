#!/bin/bash

DB_FILE="./private/LocalSync.db"

TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
if [ -x "$TERMUX_BASH" ]; then
    BASH_CMD="su -c $TERMUX_BASH"
else
    BASH_CMD="bash"
fi

# Define .sh files to exclude from the list
unlisted_sh_files=("hidden.sh" "test.sh" "start_shortcut.sh" "util_detect_env.sh" "util_send_files.sh" "util_send_folder.sh" "util_receive_files.sh" "util_receive_folder.sh")

# Set utility paths and determine IP based on environment
ENVIRONMENT=$($BASH_CMD util_detect_env.sh)
case "$ENVIRONMENT" in
"termux")
    JQ="/data/data/com.termux/files/usr/bin/jq"
    IFCONFIG="/data/data/com.termux/files/usr/bin/ifconfig"
    SQLITE3="/data/data/com.termux/files/usr/bin/sqlite3"
    CURL="curl"
    ;;
"msys")
    JQ="C:/msys64/ucrt64/bin/jq.exe"
    IFCONFIG=""
    SQLITE3="C:/msys64/ucrt64/bin/sqlite3"
    CURL="curl"
    ;;
*)
    echo "Unknown environment: $ENVIRONMENT"
    exit 1
    ;;
esac

# Determine current device IP
if [ -n "$IFCONFIG" ] && command -v "$IFCONFIG" &>/dev/null; then
    CURRENT_IP=$("$IFCONFIG" | awk '
      $1 == "wlan0:" { in_wlan=1; next }
      in_wlan && $1 == "inet" { print $2; exit }
    ')
elif [ "$ENVIRONMENT" = "msys" ]; then
    CURRENT_IP=$(ipconfig | grep -E "IPv4|IPv4 Address" | awk -F: '{print $2}' | sed 's/^[ \t]*//;s/\r$//' | head -n1)
else
    CURRENT_IP="127.0.0.1"
fi

# Initialize the database if it doesn't exist
init_db() {
    $SQLITE3 "$DB_FILE" "
        CREATE TABLE IF NOT EXISTS devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            IPAddress TEXT NOT NULL UNIQUE,
            currentDirectory TEXT
        );"
}

register_self_device() {
    echo "Registering self device..."
    local self_ip="$CURRENT_IP"
    local self_name=$($CURL -s "http://$self_ip:3000/get_device_name" | $JQ -r '.name')
    if [ -z "$self_name" ] || [ "$self_name" = "null" ]; then
        self_name="UnknownDevice"
    fi

    local self_directory=$(pwd)
    if [ -z "$self_directory" ] || [ "$self_directory" = "null" ]; then
        self_directory="/"
    fi

    local exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE IPAddress='$self_ip';")
    if [ "$exists" -eq 0 ]; then
        echo "Adding device: $self_name ($self_ip)"
        $SQLITE3 "$DB_FILE" "
            INSERT INTO devices (name, IPAddress, currentDirectory)
            VALUES ('$self_name', '$self_ip', '$self_directory');
        "
        echo "Device registered!"
    else
        # Check if the current directory has changed
        local stored_directory=$($SQLITE3 "$DB_FILE" "SELECT currentDirectory FROM devices WHERE IPAddress='$self_ip';")
        if [ "$self_directory" != "$stored_directory" ]; then
            echo "Updating directory for device: $self_name ($self_ip) to $self_directory"
            $SQLITE3 "$DB_FILE" "
                UPDATE devices
                SET currentDirectory='$self_directory'
                WHERE IPAddress='$self_ip';
            "
            echo "Directory updated!"
        else
            echo "Device already registered with current directory."
        fi
    fi
}

# --- Check if at least one other device exists ---
check_devices_count() {
    local count=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE IPAddress!='$CURRENT_IP';")
    if [ "$count" -eq 0 ]; then
        echo "No other device detected in database!"
        echo "You need to add at least one other device first."
        read -p "Press Enter to continue..."
    fi
}

init_db
register_self_device
check_devices_count

while true; do
    cd "$(dirname "$0")"
    # Get the current script directory
    script_path=$(pwd)
    # Get the directory path from the Flask API
    ENVIRONMENT=$($BASH_CMD util_detect_env.sh)

    clear

    echo $ENVIRONMENT
    echo "Shell Script Launcher"

    current_script="$(basename "$0")"
    index=1
    sh_files=""

    for file in *.sh; do
        # Skip the launcher script itself
        [ "$file" = "$current_script" ] && continue

        # Skip unlisted files
        skip=false
        for excluded in "${unlisted_sh_files[@]}"; do
            if [ "$file" = "$excluded" ]; then
                skip=true
                break
            fi
        done
        $skip && continue

        sh_files="${sh_files}${index}:${file}\n"
        index=$((index + 1))
    done

    total_files=$((index - 1))

    if [ "$total_files" -eq 0 ]; then
        echo "No .sh files found in the current directory."
        exit 1
    fi

    printf "%b" "$sh_files" | while IFS=: read i name; do
        echo "[$i] $name"
    done
    echo "[0] Quit"

    echo
    printf "Select a script to run by number: "
    read choice

    case "$choice" in
    0)
        echo "Goodbye!"
        exit 0
        ;;
    '' | *[!0-9]*)
        echo "Invalid input. Please enter a number."
        sleep 1
        continue
        ;;
    *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$total_files" ]; then
            selected_file=$(printf "%b" "$sh_files" | awk -F: -v n="$choice" '$1 == n { print $2 }')
            dos2unix "$selected_file"
            echo "Running '$selected_file'..."
            if [ "$ENVIRONMENT" = "termux" ]; then
                /data/data/com.termux/files/usr/bin/bash "$selected_file"
            else
                bash "$selected_file"
            fi

            echo
            printf "Press Enter to return to menu..."
            read dummy
        else
            echo "Invalid selection."
            sleep 1
        fi
        ;;
    esac
done