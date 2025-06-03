#!/bin/bash

DB_FILE="./private/LocalSync.db"

# Determine bash command based on environment
TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
if [ -x "$TERMUX_BASH" ]; then
    BASH_CMD="$TERMUX_BASH"
else
    BASH_CMD="bash"
fi
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
        add_device
    fi
}

list_devices() {
    echo "Listing devices..."
    $SQLITE3 -header -column "$DB_FILE" "SELECT * FROM devices;"
}

add_device() {
    read -p "Enter device IP address: " ip

    # Check if IP already exists
    local ip_exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE IPAddress='$ip';")
    if [ "$ip_exists" -gt 0 ]; then
        echo "Error: IP address $ip already exists in the database."
        return 1
    fi

    device_name=$($CURL -s "http://$ip:3000/get_device_name" | $JQ -r '.name')
    if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
        read -p "Could not detect device name. Enter device name manually: " device_name
    else
        echo "Detected device name: $device_name"
    fi

    server_path=$($CURL -s "http://$ip:3000/get_directory" | $JQ -r '.directory')
    echo "Current directory of the device: $server_path"

    $SQLITE3 "$DB_FILE" "
        INSERT INTO devices (name, IPAddress, currentDirectory)
        VALUES ('$device_name', '$ip', '$server_path');
    "
    echo "Device added."
}

update_device() {
    read -p "Enter device ID to update: " id

    # Verify device exists
    local exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE id=$id;")
    if [ "$exists" -eq 0 ]; then
        echo "Error: Device with ID $id does not exist."
        return 1
    fi

    current_name=$($SQLITE3 "$DB_FILE" "SELECT name FROM devices WHERE id=$id;")
    current_ip=$($SQLITE3 "$DB_FILE" "SELECT IPAddress FROM devices WHERE id=$id;")
    current_dir=$($SQLITE3 "$DB_FILE" "SELECT currentDirectory FROM devices WHERE id=$id;")

    echo "Leave field empty to keep current value."

    read -p "New name (current: $current_name): " new_name
    if [ -z "$new_name" ]; then
        new_name=$current_name
    fi

    read -p "New IP address (current: $current_ip): " new_ip
    if [ -z "$new_ip" ]; then
        new_ip=$current_ip
    fi

    # Check if new IP is already used by another device
    if [ "$new_ip" != "$current_ip" ]; then
        local ip_exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE IPAddress='$new_ip';")
        if [ "$ip_exists" -gt 0 ]; then
            echo "Error: IP address $new_ip is already used by another device."
            return 1
        fi
        server_path=$($CURL -s "http://$new_ip:3000/get_directory" | $JQ -r '.directory')
        echo "Updated current directory: $server_path"
    else
        server_path=$current_dir
    fi

    $SQLITE3 "$DB_FILE" "
        UPDATE devices
        SET name='$new_name', IPAddress='$new_ip', currentDirectory='$server_path'
        WHERE id=$id;
    "
    echo "Device updated."
}

reset_database() {
    read -p "Are you sure you want to reset the database? This will delete all data. [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -f "$DB_FILE"
        init_db
        echo "Database has been reset."
        register_self_device
        check_devices_count
    else
        echo "Reset cancelled."
    fi
}

delete_device() {
    read -p "Enter device ID to delete: " id
    $SQLITE3 "$DB_FILE" "DELETE FROM devices WHERE id=$id;"
    echo "Device deleted."
}

show_menu() {
    echo "LocalSync Device Manager"
    echo "1) List devices"
    echo "2) Add device"
    echo "3) Update device"
    echo "4) Delete device"
    echo "5) Reset database"
    echo "0) Exit"
}

# Initialize and register self
init_db
register_self_device
check_devices_count

# --- Main Loop ---
while true; do
    ./file_sync_operation.sh "receive_database"
    show_menu
    read -p "Select an option [0-5]: " option
    case $option in
    1) list_devices ;;
    2) add_device ;;
    3) update_device ;;
    4) delete_device ;;
    5) reset_database ;;
    0)
        echo "Goodbye!"
        exit 0
        ;;
    *) echo "Invalid option. Try again." ;;
    esac
    ./file_sync_operation.sh "send_database"
    echo "---------------------------------------"
done