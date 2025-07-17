#!/bin/bash

DB_FILE="./private/LocalSync.db"
DB_DIR=$(dirname "$DB_FILE")

if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR"
fi

if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
fi

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
            device_name TEXT NOT NULL,
            local_ip_address TEXT NOT NULL UNIQUE,
            wlan_address TEXT,
            wlan_network TEXT,
            current_directory TEXT,
            availability_status TEXT DEFAULT 'unknown',
            environment TEXT DEFAULT 'unknown',
            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );"
}

register_self_device() {
    echo "Registering self device..."
    echo "Debug: Current IP = $CURRENT_IP"
    echo "Debug: Environment = $ENVIRONMENT"
    
    local self_ip="$CURRENT_IP"
    case "$ENVIRONMENT" in
    "termux")
        # Android/Termux: Get user from whoami and model from getprop
        user=$(whoami 2>/dev/null || echo "unknown")
        model=$(getprop ro.product.model 2>/dev/null | tr -d '\n')
        if [ -z "$model" ]; then
            # Fallback: Check if running on a Linux PC
            if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
                model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null | tr -d '\n')
            else
                model="UnknownAndroid"
            fi
        fi
        self_name="${model} (${user})"
        ;;
    "msys")
        # Windows/MSYS: Get username and use hostname as model
        user=$(whoami 2>/dev/null || echo "unknown")
        echo "Debug: Got user = $user"
        
        # Use hostname instead of wmic to avoid hanging
        model=$(hostname 2>/dev/null || echo "WindowsPC")
        echo "Debug: Got hostname = $model"
        self_name="${model} (${user})"
        ;;
    *)
        echo "Unknown environment: $ENVIRONMENT"
        exit 1
        ;;
    esac

    local self_directory=$(pwd)
    if [ -z "$self_directory" ] || [ "$self_directory" = "null" ]; then
        self_directory="/"
    fi
    
    echo "Debug: Device name = $self_name"
    echo "Debug: Directory = $self_directory"
    echo "Debug: About to check database..."

    local exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$self_ip';" 2>/dev/null)
    if [ -z "$exists" ]; then
        exists=0
    fi
    
    echo "Debug: Device exists check = $exists"
    
    if [ "$exists" -eq 0 ]; then
        echo "Adding device: $self_name ($self_ip)"
        $SQLITE3 "$DB_FILE" "
            INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
            VALUES ('$self_name', '$self_ip', '$self_ip', '$(echo "$self_ip" | cut -d"." -f1-3)', '$self_directory', 'online', '$ENVIRONMENT', datetime('now'));
        "
        echo "Device registered!"
    else
        # Check if the current directory has changed
        local stored_directory=$($SQLITE3 "$DB_FILE" "SELECT current_directory FROM devices WHERE local_ip_address='$self_ip';" 2>/dev/null)
        if [ "$self_directory" != "$stored_directory" ]; then
            echo "Updating directory for device: $self_name ($self_ip) to $self_directory"
            $SQLITE3 "$DB_FILE" "
                UPDATE devices
                SET current_directory='$self_directory',
                    last_seen=datetime('now'),
                    updated_at=datetime('now')
                WHERE local_ip_address='$self_ip';
            "
            echo "Directory updated!"
        else
            echo "Device already registered with current directory."
        fi
    fi
}

# --- Check if at least one other device exists ---
check_devices_count() {
    local count=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address!='$CURRENT_IP';" 2>/dev/null)
    if [ -z "$count" ]; then
        count=0
    fi
    
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
            # Convert line endings if dos2unix is available
            if command -v dos2unix >/dev/null 2>&1; then
                dos2unix "$selected_file"
            fi
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