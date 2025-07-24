#!/bin/bash

# Network scanning utilities for LocalSync
# This file contains shared functions for network device discovery

# Helper function to get network segment from IP
get_network_segment() {
    local ip="$1"
    echo "$ip" | cut -d'.' -f1-3
}

# Helper function to get device MAC or hardware identifier
get_device_identifier() {
    local ip="$1"
    
    # Try to get device identifier from the LocalSync server
    local device_id=$($CURL -s --connect-timeout 1 "http://$ip:3000/get_device_id" 2>/dev/null | $JQ -r '.id' 2>/dev/null)
    if [ -n "$device_id" ] && [ "$device_id" != "null" ]; then
        echo "$device_id"
        return 0
    fi
    
    # Fallback: use device name + environment as identifier
    local device_name=$($CURL -s --connect-timeout 1 "http://$ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
    local environment=$($CURL -s --connect-timeout 1 "http://$ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
    
    if [ -n "$device_name" ] && [ "$device_name" != "null" ] && [ -n "$environment" ] && [ "$environment" != "null" ]; then
        echo "${device_name}_${environment}"
    else
        echo ""
    fi
}

# Function to check if a device is online and running LocalSync
is_device_online() {
    local ip="$1"
    local timeout="${2:-1}"  # Default timeout of 1 second
    
    # Skip ping entirely - go straight to LocalSync check
    # Many devices block ping but allow HTTP, so this is more reliable
    local response=$($CURL -s --connect-timeout $timeout "http://$ip:3000/api/environment" 2>/dev/null)
    
    # Debug output (only when DEBUG_SCAN is set)
    if [ -n "$DEBUG_SCAN" ]; then
        echo "Debug: Response from $ip: '$response'" >&2
    fi
    
    if [ -n "$response" ] && echo "$response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
        return 0  # Device is online and running LocalSync
    else
        return 1  # Device not running LocalSync or not responding
    fi
}

# Network scanning function for LocalSync devices
# Parameters:
#   $1 - Current IP address
#   $2 - Database file path
#   $3 - Environment (msys, termux, linux)
#   $4 - Interactive mode (true/false) - whether to prompt for IP changes
util_scan_network_for_devices() {
    local current_ip="$1"
    local db_file="$2"
    local environment="$3"
    local interactive="${4:-true}"
    
    echo "Scanning local network for LocalSync devices..."
    
    # Get network base from current IP
    if [ -z "$current_ip" ] || [ "$current_ip" = "127.0.0.1" ]; then
        echo "Error: Cannot determine current IP address for network scanning."
        return 1
    fi
    
    local current_network=$(get_network_segment "$current_ip")
    local found_count=0
    
    # Method 1: Try zeroconf discovery first (fast)
    echo "Checking for zeroconf-discovered devices..."
    local zeroconf_response=$($CURL -s --connect-timeout 1 "http://$current_ip:3000/api/discover_services" 2>/dev/null)
    if [ $? -eq 0 ] && echo "$zeroconf_response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
        local services=$(echo "$zeroconf_response" | $JQ -r '.services[]? | "\(.host)|\(.name)"' 2>/dev/null)
        if [ -n "$services" ]; then
            echo "Found devices via zeroconf discovery:"
            while IFS='|' read -r ip name; do
                if [ -n "$ip" ] && [ "$ip" != "$current_ip" ]; then
                    echo "Found LocalSync device at: $ip ($name)"
                    
                    # Verify device is still responding
                    local response=$($CURL -s --connect-timeout 1 "http://$ip:3000/api/environment" 2>/dev/null)
                    if echo "$response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
                        # Check if device already exists in database
                        local exists_by_ip=$($SQLITE3 "$db_file" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$ip';" 2>/dev/null)
                        if [ -z "$exists_by_ip" ]; then
                            exists_by_ip=0
                        fi
                        
                        if [ "$exists_by_ip" -eq 0 ]; then
                            # Add new device
                            local device_name=$($CURL -s --connect-timeout 1 "http://$ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                            if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
                                device_name="$name"
                            fi
                            
                            local server_path=$($CURL -s --connect-timeout 1 "http://$ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
                            if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
                                server_path="/"
                            fi
                            
                            local device_environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                            if [ -z "$device_environment" ] || [ "$device_environment" = "null" ]; then
                                device_environment="unknown"
                            fi
                            
                            # Add to database
                            $SQLITE3 "$db_file" "
                                INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
                                VALUES ('$device_name', '$ip', '$ip', '$current_network', '$server_path', 'online', '$device_environment', datetime('now'));
                            "
                            echo "  → Added: $device_name ($ip)"
                            found_count=$((found_count + 1))
                        else
                            echo "  → Already in database: $ip"
                            # Update status and last_seen
                            $SQLITE3 "$db_file" "
                                UPDATE devices 
                                SET availability_status='online', 
                                    wlan_network='$current_network',
                                    last_seen=datetime('now')
                                WHERE local_ip_address='$ip';
                            "
                        fi
                    fi
                fi
            done <<< "$services"
        fi
    fi
    
    # Method 2: Fallback to manual scanning if no zeroconf results
    if [ "$found_count" -eq 0 ]; then
        echo "No zeroconf devices found. Falling back to network scanning..."
        echo "Scanning network range: ${current_network}.1-254"
        
        # Common IP ranges to check
        local common_ranges="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 50 51 52 53 54 55 100 101 102 103 104 105 106 107 108 109 110 150 151 152 153 154 155 200 201 202 203 204 205 250 251 252 253 254"
        
        echo "Quick scan of common IP ranges..."
        
        for i in $common_ranges; do
            local target_ip="${current_network}.${i}"
            
            # Skip self
            if [ "$target_ip" = "$current_ip" ]; then
                continue
            fi
            
            echo -n "Scanning $target_ip... "
            
            # Use the same device online check function for consistency
            if is_device_online "$target_ip" 1; then
                echo "LocalSync device found!"
                
                # (Add device logic same as above...)
                local exists_by_ip=$($SQLITE3 "$db_file" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$target_ip';" 2>/dev/null)
                if [ -z "$exists_by_ip" ]; then
                    exists_by_ip=0
                fi
                
                if [ "$exists_by_ip" -eq 0 ]; then
                    local device_name=$($CURL -s --connect-timeout 1 "http://$target_ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                    if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
                        device_name="LocalSync Device"
                    fi
                    
                    local server_path=$($CURL -s --connect-timeout 1 "http://$target_ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
                    if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
                        server_path="/"
                    fi
                    
                    local device_environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                    if [ -z "$device_environment" ] || [ "$device_environment" = "null" ]; then
                        device_environment="unknown"
                    fi
                    
                    $SQLITE3 "$db_file" "
                        INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
                        VALUES ('$device_name', '$target_ip', '$target_ip', '$current_network', '$server_path', 'online', '$device_environment', datetime('now'));
                    "
                    echo "  → Added: $device_name ($target_ip)"
                    found_count=$((found_count + 1))
                else
                    echo "  → Already in database: $target_ip"
                    $SQLITE3 "$db_file" "
                        UPDATE devices 
                        SET availability_status='online', 
                            wlan_network='$current_network',
                            last_seen=datetime('now')
                        WHERE local_ip_address='$target_ip';
                    "
                fi
            else
                echo "no LocalSync server"
            fi
        done
        
        # Ask for full scan if still no results
        if [ "$found_count" -eq 0 ] && [ "$interactive" = "true" ]; then
            echo "No devices found in common IP ranges."
            read -p "Perform full network scan (1-254)? This may take several minutes. [y/N]: " full_scan
            if [[ "$full_scan" == "y" || "$full_scan" == "Y" ]]; then
                echo "Performing full network scan..."
                echo "Scanning all IPs from ${current_network}.1 to ${current_network}.254..."
                
                # Full scan of all IPs
                for i in $(seq 1 254); do
                    local target_ip="${current_network}.${i}"
                    
                    # Skip self and already scanned common ranges
                    if [ "$target_ip" = "$current_ip" ] || [[ " $common_ranges " =~ " $i " ]]; then
                        continue
                    fi
                    
                    echo -n "Scanning $target_ip... "
                    
                    # Use the same device online check function for consistency
                    if is_device_online "$target_ip" 1; then
                        echo "LocalSync device found!"
                        
                        # Check if device already exists
                        local exists_by_ip=$($SQLITE3 "$db_file" "SELECT COUNT(*) FROM devices WHERE local_ip_address='$target_ip';" 2>/dev/null)
                        if [ -z "$exists_by_ip" ]; then
                            exists_by_ip=0
                        fi
                        
                        if [ "$exists_by_ip" -eq 0 ]; then
                            local device_name=$($CURL -s --connect-timeout 3 "http://$target_ip:3000/get_device_name" | $JQ -r '.name' 2>/dev/null)
                            if [ -z "$device_name" ] || [ "$device_name" = "null" ]; then
                                device_name="LocalSync Device"
                            fi
                            
                            local server_path=$($CURL -s --connect-timeout 3 "http://$target_ip:3000/get_directory" | $JQ -r '.directory' 2>/dev/null)
                            if [ -z "$server_path" ] || [ "$server_path" = "null" ]; then
                                server_path="/"
                            fi
                            
                            local device_environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                            if [ -z "$device_environment" ] || [ "$device_environment" = "null" ]; then
                                device_environment="unknown"
                            fi
                            
                            $SQLITE3 "$db_file" "
                                INSERT INTO devices (device_name, local_ip_address, wlan_address, wlan_network, current_directory, availability_status, environment, last_seen)
                                VALUES ('$device_name', '$target_ip', '$target_ip', '$current_network', '$server_path', 'online', '$device_environment', datetime('now'));
                            "
                            echo "  → Added: $device_name ($target_ip)"
                            found_count=$((found_count + 1))
                        else
                            echo "  → Already in database: $target_ip"
                            $SQLITE3 "$db_file" "
                                UPDATE devices 
                                SET availability_status='online', 
                                    wlan_network='$current_network',
                                    last_seen=datetime('now')
                                WHERE local_ip_address='$target_ip';
                            "
                        fi
                        else
                            echo "no LocalSync server"
                        fi
                done
                
                echo "Full network scan completed. Found $found_count total device(s)."
            fi
        fi
    fi
    
    # Mark devices from other networks as offline
    echo "Marking devices from other networks as offline..."
    $SQLITE3 "$db_file" "
        UPDATE devices 
        SET availability_status='offline',
            updated_at=datetime('now')
        WHERE wlan_network != '$current_network' AND local_ip_address != '$current_ip';
    "
    
    # Simple summary message
    if [ "$found_count" -eq 0 ]; then
        echo "No LocalSync devices found in current network ($current_network.x)."
    else
        echo "Found $found_count LocalSync device(s) in current network ($current_network.x)."
    fi
    return $found_count
}

# Function to refresh status of existing devices
# Parameters:
#   $1 - Current IP address
#   $2 - Database file path
util_refresh_device_status() {
    local current_ip="$1"
    local db_file="$2"
    
    echo "Refreshing status of existing devices..."
    
    local current_network=$(get_network_segment "$current_ip")
    echo "Checking devices in network: $current_network.x"
    
    # Get devices from current network only
    local devices=$($SQLITE3 "$db_file" "SELECT local_ip_address || '|' || device_name FROM devices WHERE local_ip_address != '$current_ip' AND wlan_network = '$current_network';")
    
    if [ -z "$devices" ]; then
        echo "No devices found in the current network ($current_network.x)."
        return 0
    fi
    
    local checked_count=0
    local online_count=0
    
    # Convert multiline to array for safer processing
    local -a device_array
    while IFS= read -r line; do
        device_array+=("$line")
    done <<< "$devices"
    
    # Process each device
    for device_line in "${device_array[@]}"; do
        if [ -n "$device_line" ]; then
            local ip=$(echo "$device_line" | cut -d'|' -f1)
            local name=$(echo "$device_line" | cut -d'|' -f2-)
            
            if [ -n "$ip" ] && [ -n "$name" ]; then
                checked_count=$((checked_count + 1))
                echo "Checking device: $name ($ip)"
                
                # Try to connect to device
                if is_device_online "$ip"; then
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
                    
                    local response=$($CURL -s --connect-timeout 3 "http://$ip:3000/api/environment" 2>/dev/null)
                    local environment=$(echo "$response" | $JQ -r '.environment' 2>/dev/null)
                    if [ -z "$environment" ] || [ "$environment" = "null" ]; then
                        environment="unknown"
                    fi
                    
                    # Update database
                    $SQLITE3 "$db_file" "
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
                    $SQLITE3 "$db_file" "
                        UPDATE devices 
                        SET availability_status='offline',
                            updated_at=datetime('now')
                        WHERE local_ip_address='$ip';
                    "
                fi
            fi
        fi
    done
    
    echo "Status refresh completed for devices in network $current_network.x"
    echo "Checked $checked_count device(s), found $online_count online"
    
    # Remove duplicate offline devices on the same network
    echo "Checking for duplicate offline devices..."
    
    # Get device names that have duplicates on the current network
    local duplicate_names=$($SQLITE3 "$db_file" "
        SELECT device_name 
        FROM devices 
        WHERE wlan_network = '$current_network' 
        AND local_ip_address != '$current_ip'
        GROUP BY device_name 
        HAVING COUNT(*) > 1;
    " 2>/dev/null)
    
    if [ -n "$duplicate_names" ]; then
        local removed_count=0
        while IFS= read -r device_name; do
            if [ -n "$device_name" ]; then
                # Check if ALL devices with this name on this network are offline
                local total_devices=$($SQLITE3 "$db_file" "
                    SELECT COUNT(*) 
                    FROM devices 
                    WHERE device_name = '$device_name' 
                    AND wlan_network = '$current_network' 
                    AND local_ip_address != '$current_ip';
                " 2>/dev/null)
                
                local offline_devices=$($SQLITE3 "$db_file" "
                    SELECT COUNT(*) 
                    FROM devices 
                    WHERE device_name = '$device_name' 
                    AND wlan_network = '$current_network' 
                    AND local_ip_address != '$current_ip' 
                    AND availability_status = 'offline';
                " 2>/dev/null)
                
                if [ -n "$total_devices" ] && [ -n "$offline_devices" ] && [ "$total_devices" -gt 1 ] && [ "$offline_devices" -lt "$total_devices" ]; then
                    # Some devices are online, so we can safely remove the offline duplicates
                    echo "  → Removing offline duplicates for '$device_name' (keeping online devices)"
                    
                    # Get the IDs of offline duplicate devices (keep the most recent one)
                    local offline_ids=$($SQLITE3 "$db_file" "
                        SELECT id 
                        FROM devices 
                        WHERE device_name = '$device_name' 
                        AND wlan_network = '$current_network' 
                        AND local_ip_address != '$current_ip' 
                        AND availability_status = 'offline'
                        ORDER BY last_seen DESC 
                        LIMIT -1 OFFSET 1;
                    " 2>/dev/null)
                    
                    if [ -n "$offline_ids" ]; then
                        while IFS= read -r device_id; do
                            if [ -n "$device_id" ]; then
                                $SQLITE3 "$db_file" "DELETE FROM devices WHERE id = '$device_id';" 2>/dev/null
                                removed_count=$((removed_count + 1))
                            fi
                        done <<< "$offline_ids"
                    fi
                elif [ -n "$total_devices" ] && [ -n "$offline_devices" ] && [ "$total_devices" -gt 1 ] && [ "$offline_devices" -eq "$total_devices" ]; then
                    # All devices with this name are offline - keep them all since we can't determine which is real
                    echo "  → Keeping all offline duplicates for '$device_name' (all offline, cannot determine real device)"
                fi
            fi
        done <<< "$duplicate_names"
        
        if [ $removed_count -gt 0 ]; then
            echo "Removed $removed_count duplicate offline device(s)"
        fi
    fi
    
    # Also mark devices from other networks as offline since we can't reach them
    echo "Marking devices from other networks as offline..."
    $SQLITE3 "$db_file" "
        UPDATE devices 
        SET availability_status='offline',
            updated_at=datetime('now')
        WHERE wlan_network != '$current_network' AND local_ip_address != '$current_ip';
    "
    
    # Count how many devices were marked offline from other networks
    local other_network_count=$($SQLITE3 "$db_file" "SELECT COUNT(*) FROM devices WHERE wlan_network != '$current_network' AND local_ip_address != '$current_ip' AND availability_status = 'offline';" 2>/dev/null)
    if [ -n "$other_network_count" ] && [ "$other_network_count" -gt 0 ]; then
        echo "Marked $other_network_count device(s) from other networks as offline"
    fi
}

# Function to mark devices from other networks as offline
# Parameters:
#   $1 - Current IP address
#   $2 - Database file path
util_mark_other_networks_offline() {
    local current_ip="$1"
    local db_file="$2"
    
    local current_network=$(get_network_segment "$current_ip")
    
    # Mark devices from other networks as offline
    $SQLITE3 "$db_file" "
        UPDATE devices 
        SET availability_status='offline',
            updated_at=datetime('now')
        WHERE wlan_network != '$current_network' AND local_ip_address != '$current_ip';
    "
}
