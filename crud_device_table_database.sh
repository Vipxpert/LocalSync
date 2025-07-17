#!/bin/bash

DB_FILE="./private/LocalSync.db"
DB_DIR=$(dirname "$DB_FILE")

if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR"
fi

if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
fi

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
"linux")
    JQ="jq"
    IFCONFIG="ifconfig"
    SQLITE3="sqlite3"
    CURL="curl"
    ;;
*)
    echo "Unknown environment: $ENVIRONMENT"
    echo "Trying to use default commands..."
    JQ="jq"
    IFCONFIG="ifconfig"
    SQLITE3="sqlite3"
    CURL="curl"
    ;;
esac

# Determine current device IP
if [ -n "$IFCONFIG" ] && command -v "$IFCONFIG" &>/dev/null; then
    if [ "$ENVIRONMENT" = "linux" ]; then
        # Linux IP detection
        CURRENT_IP=$("$IFCONFIG" | grep -E "inet.*broadcast" | grep -v "127.0.0.1" | awk '{print $2}' | head -n1)
        if [ -z "$CURRENT_IP" ]; then
            # Fallback: try wlan0 specifically
            CURRENT_IP=$("$IFCONFIG" wlan0 2>/dev/null | grep "inet " | awk '{print $2}')
        fi
    else
        # Termux IP detection
        CURRENT_IP=$("$IFCONFIG" | awk '
          $1 == "wlan0:" { in_wlan=1; next }
          in_wlan && $1 == "inet" { print $2; exit }
        ')
    fi
elif [ "$ENVIRONMENT" = "msys" ] || [ "$ENVIRONMENT" = "linux" ]; then
    # Windows/MSYS IP detection (and fallback for misdetected linux)
    CURRENT_IP=$(ipconfig 2>/dev/null | grep -E "IPv4|IPv4 Address" | head -n1 | cut -d: -f2 | sed 's/^[ \t]*//;s/\r$//')
    if [ -z "$CURRENT_IP" ]; then
        # Alternative Windows method
        CURRENT_IP=$(ipconfig 2>/dev/null | findstr "IPv4" | head -n1 | cut -d: -f2 | sed 's/^[ \t]*//')
    fi
else
    CURRENT_IP="127.0.0.1"
fi

# If still no IP found, try fallback method
if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" = "127.0.0.1" ]; then
    echo "Warning: Could not detect current IP address, using 127.0.0.1"
    CURRENT_IP="127.0.0.1"
fi

echo "Debug: Environment=$ENVIRONMENT, Current IP=$CURRENT_IP"

# Helper function to get network segment from IP
get_network_segment() {
    local ip="$1"
    echo "$ip" | cut -d'.' -f1-3
}

# Helper function to get device MAC or hardware identifier
get_device_identifier() {
    local ip="$1"
    
    # Try to get device identifier from the LocalSync server
    local device_id=$($CURL -s --connect-timeout 3 "http://$ip:3000/get_device_id" 2>/dev/null | $JQ -r '.id' 2>/dev/null)
    if [ -n "$device_id" ] && [ "$device_id" != "null" ]; then
        echo "$device_id"
        return 0
    fi
    
    # Fallback: use device name + environment as identifier
    local device_name=$($CURL -s --connect-timeout 3 "http://$ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
    local environment=$($CURL -s --connect-timeout 3 "http://$ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
    
    if [ -n "$device_name" ] && [ "$device_name" != "null" ] && [ -n "$environment" ] && [ "$environment" != "null" ]; then
        echo "${device_name}_${environment}"
    else
        echo ""
    fi
}

# Initialize the database if it doesn't exist
init_db() {
    # Check if table exists
    local table_exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='devices';" 2>/dev/null || echo "0")
    
    if [ "$table_exists" -gt 0 ]; then
        # Check if we have the new schema with wlan_network column
        local has_wlan_network=$($SQLITE3 "$DB_FILE" "PRAGMA table_info(devices);" 2>/dev/null | grep -c "wlan_network")
        
        if [ "$has_wlan_network" -gt 0 ]; then
            # Database already has new schema, no migration needed
            echo "Database schema is up to date."
            return 0
        fi
        
        # Need to migrate to add wlan_network column
        echo "Migrating database schema to include WLAN network info..."
        
        # Add wlan_network column to existing table
        $SQLITE3 "$DB_FILE" "ALTER TABLE devices ADD COLUMN wlan_network TEXT;" 2>/dev/null
        
        # Update existing records with network info
        $SQLITE3 "$DB_FILE" "
            UPDATE devices 
            SET wlan_network = SUBSTR(local_ip_address, 1, LENGTH(local_ip_address) - LENGTH(SUBSTR(local_ip_address, INSTR(local_ip_address, '.', INSTR(local_ip_address, '.', INSTR(local_ip_address, '.') + 1) + 1) + 1)))
            WHERE wlan_network IS NULL;
        "
        
        echo "Database migration completed."
    else
        # Create new table
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
            );
        "
    fi
}

register_self_device() {
    echo "Registering self device..."

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
        environment="android"
        ;;
    "msys")
        # Windows/MSYS: Get username and use hostname as model
        user=$(whoami 2>/dev/null || echo "unknown")
        model=$(hostname 2>/dev/null || echo "WindowsPC")
        if [ -z "$model" ]; then
            model="UnknownWindows"
        fi
        self_name="${model} (${user})"
        environment="windows"
        ;;
    "linux")
        # Linux: Get user and hostname/model
        user=$(whoami 2>/dev/null || echo "unknown")
        if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
            model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null | tr -d '\n')
        else
            model=$(hostname 2>/dev/null || echo "UnknownLinux")
        fi
        self_name="${model} (${user})"
        environment="linux"
        ;;
    *)
        echo "Unknown environment: $ENVIRONMENT, using defaults"
        user=$(whoami 2>/dev/null || echo "unknown")
        model=$(hostname 2>/dev/null || echo "UnknownDevice")
        self_name="${model} (${user})"
        environment="unknown"
        ;;
    esac

    local self_directory=$(pwd)
    if [ -z "$self_directory" ] || [ "$self_directory" = "null" ]; then
        self_directory="/"
    fi

    local self_network=$(get_network_segment "$self_ip")

    local exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$self_ip';" 2>/dev/null)
    if [ -z "$exists" ]; then
        exists=0
    fi
    
    if [ "$exists" -eq 0 ]; then
        echo "Adding device: $self_name ($self_ip)"
        $SQLITE3 "$DB_FILE" "
            INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
            VALUES ('$self_name', '$self_ip', '$self_ip', '$self_network', '$self_directory', 'online', '$environment', datetime('now'));
        "
        echo "Device registered!"
    else
        # Update existing device
        echo "Updating device: $self_name ($self_ip)"
        $SQLITE3 "$DB_FILE" "
            UPDATE devices
            SET device_name='$self_name', 
                wlan_network='$self_network',
                current_directory='$self_directory', 
                availability_status='online',
                environment='$environment',
                last_seen=datetime('now'),
                updated_at=datetime('now')
            WHERE local_ip_address='$self_ip';
        "
        echo "Device updated!"
    fi
    
    # Check for actual duplicates (same device name on same network but different IPs)
    # This would be unusual and likely indicates an IP change on the same network
    local self_network=$(get_network_segment "$self_ip")
    local duplicate_count=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE device_name='$self_name' AND local_ip_address!='$self_ip' AND wlan_network='$self_network';" 2>/dev/null)
    if [ "$duplicate_count" -gt 0 ]; then
        echo "Found $duplicate_count duplicate device(s) with the same name on the same network ($self_network.x) but different IP addresses."
        echo "This usually happens when your device's IP changed on the same network."
        read -p "Remove old entries on this network? [y/N]: " remove_duplicates
        if [[ "$remove_duplicates" == "y" || "$remove_duplicates" == "Y" ]]; then
            local removed=$($SQLITE3 "$DB_FILE" "DELETE FROM devices WHERE device_name='$self_name' AND local_ip_address!='$self_ip' AND wlan_network='$self_network';" 2>/dev/null && echo "1" || echo "0")
            if [ "$removed" = "1" ]; then
                echo "Removed duplicate entries for $self_name on network $self_network.x"
            fi
        fi
    fi
}

# --- Check if at least one other device exists ---
check_devices_count() {
    # Update missing wlan_network fields first
    $SQLITE3 "$DB_FILE" "
        UPDATE devices 
        SET wlan_network = SUBSTR(local_ip_address, 1, LENGTH(local_ip_address) - LENGTH(SUBSTR(local_ip_address, INSTR(local_ip_address, '.', INSTR(local_ip_address, '.', INSTR(local_ip_address, '.') + 1) + 1) + 1)))
        WHERE wlan_network IS NULL OR wlan_network = '';
    " 2>/dev/null
    
    local total_count=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address!='$CURRENT_IP';" 2>/dev/null)
    local current_network=$(get_network_segment "$CURRENT_IP")
    local same_network_count=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address!='$CURRENT_IP' AND wlan_network='$current_network';" 2>/dev/null)
    
    if [ -z "$total_count" ]; then
        total_count=0
    fi
    if [ -z "$same_network_count" ]; then
        same_network_count=0
    fi
    
    if [ "$total_count" -eq 0 ]; then
        echo "No other devices detected in database!"
        echo "You can add devices manually or scan the network for LocalSync devices."
        echo "Choose option 6 for network scanning or option 2 to add manually."
    elif [ "$same_network_count" -eq 0 ] && [ "$total_count" -gt 0 ]; then
        echo "Found $total_count device(s) in database, but none in your current network ($current_network.x)."
        echo "Other devices are on different networks and may not be directly accessible."
    else
        echo "Found $total_count total device(s): $same_network_count in same network, $((total_count - same_network_count)) in other networks."
    fi
}

list_devices() {
    echo "Listing devices..."
    $SQLITE3 -header -column "$DB_FILE" "
        SELECT 
            id,
            device_name,
            local_ip_address,
            wlan_network,
            availability_status,
            environment,
            substr(last_seen, 1, 19) as last_seen
        FROM devices 
        ORDER BY last_seen DESC;
    "
}

add_device() {
    read -p "Enter device IP address: " ip

    # Check if IP already exists
    local ip_exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$ip';" 2>/dev/null)
    if [ -z "$ip_exists" ]; then
        ip_exists=0
    fi
    
    if [ "$ip_exists" -gt 0 ]; then
        echo "Error: IP address $ip already exists in the database."
        return 1
    fi

    # Try to get device info from the server
    echo "Trying to connect to device at $ip:3000..."
    device_name=$($CURL -s --connect-timeout 5 "http://$ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
    if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
        read -p "Could not detect device name. Enter device name manually: " device_name
    else
        echo "Device name detected: $device_name"
    fi

    server_path=$($CURL -s --connect-timeout 5 "http://$ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
    if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
        server_path="/"
    fi
    echo "Device current directory: $server_path"

    # Try to detect environment
    environment=$($CURL -s --connect-timeout 5 "http://$ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
    if [ -z "$environment" ] || [ "$environment" = "null" ]; then
        environment="unknown"
    fi
    echo "Device environment: $environment"

    local network=$(get_network_segment "$ip")

    $SQLITE3 "$DB_FILE" "
        INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
        VALUES ('$device_name', '$ip', '$ip', '$network', '$server_path', 'online', '$environment', datetime('now'));
    "
    echo "Device added successfully."
}

update_device() {
    read -p "Enter device ID to update: " id

    # Verify device exists
    local exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE id=$id;" 2>/dev/null)
    if [ -z "$exists" ]; then
        exists=0
    fi
    
    if [ "$exists" -eq 0 ]; then
        echo "Error: Device with ID $id does not exist."
        return 1
    fi

    current_name=$($SQLITE3 "$DB_FILE" "SELECT device_name FROM devices WHERE id=$id;")
    current_ip=$($SQLITE3 "$DB_FILE" "SELECT local_ip_address FROM devices WHERE id=$id;")
    current_dir=$($SQLITE3 "$DB_FILE" "SELECT current_directory FROM devices WHERE id=$id;")

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
        local ip_exists=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$new_ip';" 2>/dev/null)
        if [ -z "$ip_exists" ]; then
            ip_exists=0
        fi
        
        if [ "$ip_exists" -gt 0 ]; then
            echo "Error: IP address $new_ip is already used by another device."
            return 1
        fi
        
        # Try to get updated directory and environment from new IP
        server_path=$($CURL -s --connect-timeout 5 "http://$new_ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
        if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
            server_path=$current_dir
        fi
        echo "Updated current directory: $server_path"
        
        environment=$($CURL -s --connect-timeout 5 "http://$new_ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
        if [ -z "$environment" ] || [ "$environment" = "null" ]; then
            environment="unknown"
        fi
    else
        server_path=$current_dir
        environment="unknown"
    fi

    local network=$(get_network_segment "$new_ip")

    $SQLITE3 "$DB_FILE" "
        UPDATE devices
        SET device_name='$new_name', 
            local_ip_address='$new_ip', 
            wlan_address='$new_ip',
            wlan_network='$network',
            current_directory='$server_path',
            environment='$environment',
            updated_at=datetime('now')
        WHERE id=$id;
    "
    echo "Device updated successfully."
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
    echo "2) Add device manually"
    echo "3) Update device"
    echo "4) Delete device"
    echo "5) Reset database"
    echo "6) Scan network for LocalSync devices"
    echo "7) Refresh status of existing devices"
    echo "0) Exit"
}

# Network scanning function
scan_network_for_devices() {
    echo "Scanning local network for LocalSync devices..."
    
    # Get network base from current IP
    if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" = "127.0.0.1" ]; then
        echo "Error: Cannot determine current IP address for network scanning."
        return 1
    fi
    
    # Extract network base (e.g., 192.168.1.x)
    local current_network=$(get_network_segment "$CURRENT_IP")
    echo "Scanning network range: ${current_network}.1-254"
    echo "This may take a few minutes..."
    
    local found_count=0
    local scan_count=0
    
    # Scan IP range 1-254
    for i in $(seq 1 254); do
        local target_ip="${current_network}.${i}"
        
        # Skip self
        if [ "$target_ip" = "$CURRENT_IP" ]; then
            continue
        fi
        
        scan_count=$((scan_count + 1))
        
        # Show progress every 50 IPs
        if [ $((scan_count % 50)) -eq 0 ]; then
            echo "Scanned $scan_count IPs so far..."
        fi
        
        # Quick ping test first (timeout 1 second)
        local ping_result
        if [ "$ENVIRONMENT" = "msys" ]; then
            # Windows ping syntax
            ping_result=$(ping -n 1 -w 1000 "$target_ip" 2>/dev/null | grep -c "Reply from")
        else
            # Linux/Termux ping syntax
            ping_result=$(ping -c 1 -W 1 "$target_ip" >/dev/null 2>&1 && echo "1" || echo "0")
        fi
        
        if [ "$ping_result" -gt 0 ]; then
            # Try to connect to LocalSync server
            local response=$($CURL -s --connect-timeout 2 "http://$target_ip:3000/api/environment" 2>/dev/null)
            if echo "$response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
                echo "Found LocalSync device at: $target_ip"
                
                # Get device identifier to check for device that changed IP
                local device_identifier=$(get_device_identifier "$target_ip")
                
                # Check if device already exists in database by IP
                local exists_by_ip=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$target_ip';" 2>/dev/null)
                if [ -z "$exists_by_ip" ]; then
                    exists_by_ip=0
                fi
                
                # Check if device exists with same identifier but different IP (device changed IP)
                local old_device_ip=""
                if [ -n "$device_identifier" ]; then
                    # Get device details to compare
                    local device_name=$($CURL -s --connect-timeout 3 "http://$target_ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                    local environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                    
                    if [ -n "$device_name" ] && [ "$device_name" != "null" ]; then
                        # Look for existing device with same name and environment but different IP in same network
                        old_device_ip=$($SQLITE3 "$DB_FILE" "SELECT local_ip_address FROM devices WHERE device_name='$device_name' AND environment='$environment' AND wlan_network='$current_network' AND local_ip_address!='$target_ip';" 2>/dev/null)
                    fi
                fi
                
                if [ "$exists_by_ip" -eq 0 ]; then
                    # New device or device that changed IP
                    if [ -n "$old_device_ip" ]; then
                        echo "  → Device appears to have changed IP from $old_device_ip to $target_ip"
                        read -p "  → Remove old device entry ($old_device_ip) and add new one? [y/N]: " remove_old
                        if [[ "$remove_old" == "y" || "$remove_old" == "Y" ]]; then
                            # Remove old entry
                            $SQLITE3 "$DB_FILE" "DELETE FROM devices WHERE local_ip_address='$old_device_ip';"
                            echo "  → Removed old device entry: $old_device_ip"
                        fi
                    fi
                    
                    # Get device details
                    local device_name=$($CURL -s --connect-timeout 3 "http://$target_ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                    if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
                        device_name="LocalSync Device"
                    fi
                    
                    local server_path=$($CURL -s --connect-timeout 3 "http://$target_ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
                    if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
                        server_path="/"
                    fi
                    
                    local environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                    if [ -z "$environment" ] || [ "$environment" = "null" ]; then
                        environment="unknown"
                    fi
                    
                    # Add to database
                    $SQLITE3 "$DB_FILE" "
                        INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
                        VALUES ('$device_name', '$target_ip', '$target_ip', '$current_network', '$server_path', 'online', '$environment', datetime('now'));
                    "
                    echo "  → Added: $device_name ($target_ip)"
                    found_count=$((found_count + 1))
                else
                    echo "  → Already in database: $target_ip"
                    # Update status and last_seen
                    $SQLITE3 "$DB_FILE" "
                        UPDATE devices 
                        SET availability_status='online', 
                            wlan_network='$current_network',
                            last_seen=datetime('now')
                        WHERE local_ip_address='$target_ip';
                    "
                fi
            fi
        fi
    done
    
    echo "Network scan completed."
    echo "Scanned $scan_count IP addresses, found $found_count new LocalSync devices."
}

# Refresh status of existing devices (only same network)
refresh_device_status() {
    echo "Refreshing status of existing devices..."
    
    local current_network=$(get_network_segment "$CURRENT_IP")
    echo "Checking devices in network: $current_network.x"
    
    # Get all devices in the same network except self
    local devices=$($SQLITE3 "$DB_FILE" "SELECT local_ip_address, device_name FROM devices WHERE local_ip_address != '$CURRENT_IP' AND wlan_network = '$current_network';")
    
    if [ -z "$devices" ]; then
        echo "No other devices found in the same network."
        echo "Would you like to check devices from other networks? (y/n): "
        read -r cross_network_choice
        if [[ "$cross_network_choice" =~ ^[Yy]$ ]]; then
            echo "Checking devices across all networks..."
            devices=$($SQLITE3 "$DB_FILE" "SELECT local_ip_address, device_name FROM devices WHERE local_ip_address != '$CURRENT_IP';")
            if [ -z "$devices" ]; then
                echo "No other devices found in the database at all."
                return 0
            fi
        else
            echo "Staying within current network."
            return 0
        fi
    fi
    
    local checked_count=0
    local online_count=0
    
    # Process each device
    echo "$devices" | while IFS='|' read -r ip name; do
        if [ -n "$ip" ]; then
            checked_count=$((checked_count + 1))
            echo "Checking device: $name ($ip)"
            
            # Try to connect to device
            local response=$($CURL -s --connect-timeout 3 "http://$ip:3000/api/environment" 2>/dev/null)
            if echo "$response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
                echo "  → Online"
                online_count=$((online_count + 1))
                
                # Get updated info
                local device_name=$($CURL -s --connect-timeout 3 "http://$ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
                    device_name="$name"
                fi
                
                local server_path=$($CURL -s --connect-timeout 3 "http://$ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
                if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
                    server_path="/"
                fi
                
                local environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                if [ -z "$environment" ] || [ "$environment" = "null" ]; then
                    environment="unknown"
                fi
                
                # Update database
                $SQLITE3 "$DB_FILE" "
                    UPDATE devices 
                    SET device_name='$device_name',
                        current_directory='$server_path',
                        availability_status='online',
                        environment='$environment',
                        last_seen=datetime('now'),
                        updated_at=datetime('now')
                    WHERE local_ip_address='$ip';
                "
            else
                echo "  → Offline"
                # Mark as offline
                $SQLITE3 "$DB_FILE" "
                    UPDATE devices 
                    SET availability_status='offline',
                        updated_at=datetime('now')
                    WHERE local_ip_address='$ip';
                "
            fi
        fi
    done
    
    echo "Status refresh completed for devices in network $current_network.x"
}

# Initialize and register self
init_db
register_self_device
check_devices_count

# --- Main Loop ---
while true; do
    ./file_sync_operation.sh "receive_database"
    show_menu
    read -p "Select an option [0-7]: " option
    case $option in
    1) list_devices ;;
    2) add_device ;;
    3) update_device ;;
    4) delete_device ;;
    5) reset_database ;;
    6) scan_network_for_devices ;;
    7) refresh_device_status ;;
    0)
        echo "Goodbye!"
        exit 0
        ;;
    *) echo "Invalid option. Try again." ;;
    esac
    ./file_sync_operation.sh "send_database"
    echo "---------------------------------------"
done

