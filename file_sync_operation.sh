#!/bin/bash

# Run this script with ./file_sync_operation.sh operation_name
# ex ./file_sync_operation.sh receive_database
# NEW: Also supports direct file/folder paths:
# ex ./file_sync_operation.sh "C:\Users\File.txt" "C:\Users\Folder"

cd "$(dirname "$0")"

# Determine bash command based on environment
TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
if [ -x "$TERMUX_BASH" ]; then
    BASH_CMD="$TERMUX_BASH"
else
    BASH_CMD="bash"
fi
ENVIRONMENT=$($BASH_CMD util_detect_env.sh)

# Set database file path
DB_FILE="./private/LocalSync.db"

# Set utility paths based on environment
if [ "$ENVIRONMENT" = "termux" ]; then
    JQ="/data/data/com.termux/files/usr/bin/jq"
    IFCONFIG="/data/data/com.termux/files/usr/bin/ifconfig"
    SQLITE3="/data/data/com.termux/files/usr/bin/sqlite3"
    CURL="curl"
else
    JQ="C:/msys64/ucrt64/bin/jq.exe"
    IFCONFIG=""
    SQLITE3="C:/msys64/ucrt64/bin/sqlite3"
    CURL="curl"
fi

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

# Set current device's path
# if [ "$ENVIRONMENT" = "termux" ]; then
#     android_current_path=$(pwd)
# else
#     windows_current_path=$(pwd)
# fi

# SERVER_ENVIRONMENT=$(echo $($CURL -s "http://$ip:3000/api/environment") | $JQ -r '.environment')
# if [ -z "$SERVER_ENVIRONMENT" ]; then
#     echo "Error: Could not determine environment for IP $ip (connection lost or something else)"
#     continue
# fi
# server_current_path=$($CURL -s "http://$ip:3000/get_directory" | $JQ -r '.directory')


# Function to get target IPs from the database (same network by default, optional cross-network)
get_target_ips() {
    local db_file="$1"
    local current_ip="$2"
    local include_cross_network="${3:-false}"  # Default to false
    
    if [ ! -f "$db_file" ]; then
        echo "Database file not found: $db_file" >&2
        exit 1
    fi
    
    # Get current network segment
    local current_network=$(echo "$current_ip" | cut -d'.' -f1-3)
    
    if [ "$include_cross_network" = "true" ]; then
        # Get all devices except self (cross-network enabled)
        echo "Note: Including devices from all networks" >&2
        $SQLITE3 "$db_file" "SELECT local_ip_address FROM devices WHERE local_ip_address != '$current_ip';"
    else
        # Only get devices from the same network (default behavior)
        $SQLITE3 "$db_file" "SELECT local_ip_address FROM devices WHERE local_ip_address != '$current_ip' AND wlan_network = '$current_network';"
    fi
}

# Function to check if a device is online
is_device_online() {
    local ip="$1"
    local timeout=3
    
    # Test ping first (quick connectivity check)
    local ping_result=0
    if [ "$ENVIRONMENT" = "msys" ] || [ "$ENVIRONMENT" = "linux" ]; then
        # Windows ping syntax
        ping_result=$(ping -n 1 -w 1000 "$ip" 2>/dev/null | grep -c "Reply from" 2>/dev/null)
        # Ensure we have a valid number
        if [ -z "$ping_result" ] || ! [[ "$ping_result" =~ ^[0-9]+$ ]]; then
            ping_result=0
        fi
    else
        # Linux/Termux ping syntax
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            ping_result=1
        else
            ping_result=0
        fi
    fi
    
    if [ "$ping_result" -eq 0 ]; then
        return 1  # Device not reachable via ping
    fi
    
    # Test LocalSync server API endpoint
    local response=$($CURL -s --connect-timeout $timeout "http://$ip:3000/api/environment" 2>/dev/null)
    if [ -n "$response" ] && echo "$response" | $JQ -e '.status == "success"' >/dev/null 2>&1; then
        return 0  # Device is online and running LocalSync
    else
        return 1  # Device not running LocalSync or not responding
    fi
}

# Retrieve target IPs
target_ips=$(get_target_ips "$DB_FILE" "$CURRENT_IP")
if [ -z "$target_ips" ]; then
    echo "No other devices found in the same network."
    echo "Would you like to include devices from other networks? (y/n): "
    read -r cross_network_choice
    if [[ "$cross_network_choice" =~ ^[Yy]$ ]]; then
        echo "Checking devices across all networks..."
        target_ips=$(get_target_ips "$DB_FILE" "$CURRENT_IP" "true")
        if [ -z "$target_ips" ]; then
            echo "No other devices found in the database at all."
            exit 1
        fi
    else
        echo "Staying within current network. No devices found."
        exit 1
    fi
fi

# Filter online devices
echo "Checking device availability..."
online_ips=""
total_devices=0
online_devices=0

for ip in $target_ips; do
    total_devices=$((total_devices + 1))
    echo -n "Checking $ip... "
    
    if is_device_online "$ip"; then
        echo "Online"
        online_ips="$online_ips $ip"
        online_devices=$((online_devices + 1))
    else
        echo "Offline/Unreachable"
    fi
done

echo "Device status: $online_devices/$total_devices devices are online"

if [ -z "$online_ips" ]; then
    echo "No online devices found. Cannot proceed with sync operation."
    exit 1
fi

# Update target_ips to only include online devices
target_ips=$(echo $online_ips | xargs)

# Function to check if input looks like a file path
is_path() {
    local input="$1"
    
    # Check if input is a single number (not a path)
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        return 1  # false - it's just a number
    fi
    
    # Check if it contains path separators or looks like paths
    if [[ "$input" =~ [/\\] ]]; then
        return 0  # true - contains path separators
    fi
    
    # Check if it contains drive letters (Windows style paths)
    if [[ "$input" =~ [A-Za-z]: ]]; then
        return 0  # true - Windows path with drive letter
    fi
    
    # Try to check if any individual words in the input look like existing paths
    local words
    IFS=' ' read -ra words <<< "$input"
    for word in "${words[@]}"; do
        # Remove quotes if present
        word="${word%\"}"
        word="${word#\"}"
        word="${word%\'}"
        word="${word#\'}"
        
        if [[ -e "$word" ]]; then
            return 0  # true - at least one path exists
        fi
    done
    
    return 1  # false
}

# Function to process a single path
process_path() {
    local path="$1"
    local original_path="$path"
    
    # Remove quotes if present but preserve original format
    path="${path%\"}"
    path="${path#\"}"
    original_path="$path"
    
    # Check if path exists (using original Windows format)
    if [ ! -e "$original_path" ]; then
        echo "Warning: Path does not exist: $original_path"
        return 1
    fi
    
    # Convert Windows path separators to forward slashes for internal processing
    local normalized_path="${path//\\//}"
    
    echo "Processing path: $original_path"
    
    if [ -f "$original_path" ]; then
        # It's a file
        echo "File detected: $original_path"
        process_file_path "$original_path"
    elif [ -d "$original_path" ]; then
        # It's a directory
        echo "Directory detected: $original_path"
        process_directory_path "$original_path"
    else
        echo "Unknown path type: $original_path"
        return 1
    fi
}

# Function to process a file path
process_file_path() {
    local file_path="$1"
    local dir_path=$(dirname "$file_path")
    local file_name=$(basename "$file_path")
    
    # Convert paths to forward slashes for the upload utilities
    local normalized_dir_path="${dir_path//\\//}"
    
    echo "Sending file: $file_name from directory: $dir_path"
    
    # Loop through each online target IP
    for target_ip in $target_ips; do
        echo "Uploading $file_name to $target_ip..."
        
        # Get server environment
        SERVER_ENVIRONMENT=$($CURL -s --connect-timeout 5 "http://$target_ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
        if [ -z "$SERVER_ENVIRONMENT" ] || [ "$SERVER_ENVIRONMENT" = "null" ]; then
            SERVER_ENVIRONMENT="unknown"
        fi
        
        # Use util_send_files.sh to send the specific file
        $BASH_CMD util_send_files.sh "$target_ip" "$ENVIRONMENT" "$SERVER_ENVIRONMENT" 0 "$normalized_dir_path" "$normalized_dir_path" "$file_name"
    done
}

# Function to process a directory path
process_directory_path() {
    local dir_path="$1"
    
    # Convert to forward slashes for the upload utilities
    local normalized_dir_path="${dir_path//\\//}"
    
    echo "Directory found: $dir_path"
    echo "Do you want to send this directory:"
    echo "  1. Non-recursively (files in this directory only)"
    echo "  2. Recursively (all files and subdirectories)"
    echo "  3. Cancel"
    
    read -p "Enter your choice (1-3): " recursive_choice
    
    case "$recursive_choice" in
        1)
            recursive="false"
            ;;
        2)
            recursive="true"
            ;;
        3)
            echo "Cancelled directory upload for: $dir_path"
            return 0
            ;;
        *)
            echo "Invalid choice. Defaulting to non-recursive."
            recursive="false"
            ;;
    esac
    
    echo "Sending directory $dir_path (recursive: $recursive)..."
    
    # Loop through each online target IP
    for target_ip in $target_ips; do
        echo "Uploading directory to $target_ip..."
        
        # Get server environment
        SERVER_ENVIRONMENT=$($CURL -s --connect-timeout 5 "http://$target_ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
        if [ -z "$SERVER_ENVIRONMENT" ] || [ "$SERVER_ENVIRONMENT" = "null" ]; then
            SERVER_ENVIRONMENT="unknown"
        fi
        
        # Use util_send_folder.sh to send the directory
        $BASH_CMD util_send_folder.sh "$target_ip" "$ENVIRONMENT" "$SERVER_ENVIRONMENT" "$recursive" 0 "$normalized_dir_path" "$normalized_dir_path"
    done
}

# Check if arguments are provided and if they look like paths
if [ $# -gt 0 ]; then
    # Check if first argument looks like a path
    if is_path "$1"; then
        echo "Path mode detected. Processing $# path(s)..."
        
        # Process all provided paths
        for path in "$@"; do
            process_path "$path"
        done
        
        echo "All paths processed."
        exit 0
    fi
fi

# Define operations as an array of strings with delimited fields
# Format: "name|script|file_time_offset|android_path|windows_path|recursive|files|exceptions"
# name: It's just a name.
# script: There 4 .sh files you can choose from. util_send_files.sh | util_receive_files.sh | util_send_folder.sh | util_receive_folder.sh
# file_time_offset: Used to counter the time differences after sending or receive a file so that it won't always overwrite a file. For sending it should be negative, For receiving it should be positive. You can set it to infinitely opposite so it'll always be overwritten anyways.
# android_path / windows_path: The path to sync on your device. Leave it empty if you don't have one of the OS mentioned.
# recursive: true / false. Either to iterate through the entire subfolder structure or not. (Only apply to folder syncing operations)
# files: Files that you want to sync in a folder. (Only apply to file syncing operations)
# exceptions: What not to sync in the operation

operations=(
    "send_current_non_recursive|util_send_folder.sh|-35|./|./|false||private/ip_target.txt,example.txt,.DS_Store,temp*,*.log"
    "send_current_recursive|util_send_folder.sh|-35|./|./|true||private/ip_target.txt,example.txt,.DS_Store,temp*,*.log"
    "receive_current_non_recursive|util_receive_folder.sh|35|./|./|false||private/ip_target.txt,private/example.txt,logs/*.log,temp/*"
    "receive_current_recursive|util_receive_folder.sh|35|./|./|true||private/ip_target.txt,private/example.txt,logs/*.log,temp/*"
    "receive_server|util_receive_files.sh|1|./|./||server.py,templates/HTML/happy_birthday/happy-birthday.html|"
    "send_database|util_send_files.sh|-1|./private|./private||LocalSync.db|"
    "receive_database|util_receive_files.sh|1|./private|./private||LocalSync.db|"
    "send_gd_data|util_send_files.sh|-35|/storage/self/primary/Android/media/com.geode.launcher/save|C:/Users/Vipxpert/AppData/Local/GeometryDash||CCLocalLevels.dat,CCLocalLevels2.dat,CCGameManager.dat,CCGameManager2.dat|"
    "send_gd_data_non_recursive|util_send_folder.sh|-35|/storage/self/primary/Android/media/com.geode.launcher/save|C:/Users/Vipxpert/AppData/Local/GeometryDash|false||nothing"
    "receive_gd_data|util_receive_files.sh|35|/storage/self/primary/Android/media/com.geode.launcher/save|C:/Users/Vipxpert/AppData/Local/GeometryDash||CCLocalLevels.dat,CCLocalLevels2.dat,CCGameManager.dat,CCGameManager2.dat|"
    "receive_current_non_recursive|util_receive_folder.sh|35|/storage/self/primary/Android/media/com.geode.launcher/save|C:/Users/Vipxpert/AppData/Local/GeometryDash|false||nothing"
    "send_files_manually|util_send_files.sh|0|.|.||server.py|"
    "send_folder_manually|util_send_folder.sh|0|.|.|false||"
    "receive_files_manually|util_receive_files.sh|0|.|.||server.py|"
    "receive_folder_manually|util_receive_folder.sh|0|.|.|false||"
)

# Function to display numbered operation choices
display_operations() {
    echo "Available operations:"
    echo "  0. exit"
    for i in "${!operations[@]}"; do
        IFS='|' read -r name _ <<<"${operations[i]}"
        echo "  $((i + 1)). $name"
    done
}

# Function to validate operation
validate_operation() {
    local op="$1"
    for o in "${operations[@]}"; do
        IFS='|' read -r name _ <<<"$o"
        if [ "$op" = "$name" ]; then
            return 0
        fi
    done
    return 1
}

# Function to execute operation
execute_operation() {
    local operation="$1"
    local ip="$2"
    local server_env="$3"
    local op_data

    # Find the operation data
    for op in "${operations[@]}"; do
        IFS='|' read -r name script file_time_offset android_path windows_path recursive files exceptions <<<"$op"
        if [ "$name" = "$operation" ]; then
            op_data="$op"
            break
        fi
    done

    if [ -z "$op_data" ]; then
        echo "Error: Operation $operation not found."
        return 1
    fi

    # Parse operation data
    IFS='|' read -r name script file_time_offset android_path windows_path recursive files exceptions <<<"$op_data"

    # Convert comma-separated files and exceptions to arrays
    IFS=',' read -r -a files_array <<<"$files"
    IFS=',' read -r -a exceptions_array <<<"$exceptions"

    # Execute the appropriate script
    if [[ "$script" == *"folder"* ]]; then
        $BASH_CMD "./$script" "$ip" "$ENVIRONMENT" "$server_env" "$recursive" "$file_time_offset" "$android_path" "$windows_path" "${exceptions_array[@]}"
    else
        $BASH_CMD "./$script" "$ip" "$ENVIRONMENT" "$server_env" "$file_time_offset" "$android_path" "$windows_path" "${files_array[@]}"
    fi
}

# Get operation
if [ -n "$1" ]; then
    operation="$1"
    if ! validate_operation "$operation"; then
        echo "Invalid operation: $operation"
        display_operations
        echo "Please provide a valid operation name from the list above."
        exit 1
    fi
    echo "Selected operation: $operation"
else
    display_operations
    echo ""
    echo "You can also paste file/folder path(s) instead of selecting a number."
    echo "Multiple paths separated by space are supported."
    read -r -p "Enter the number of the operation to run OR paste file/folder path(s): " choice
    
    # Check if the input looks like a path
    if is_path "$choice"; then
        echo "Path input detected. Processing..."
        
        # Parse multiple paths more safely
        # Use a robust method that preserves backslashes and handles spaces
        declare -a paths
        
        # Try the simplest approach first - direct assignment
        if [[ "$choice" != *\"* ]]; then
            # No quotes, try simple space splitting
            IFS=' ' read -ra paths <<< "$choice"
        else
            # Has quotes, use eval
            eval "paths=($choice)" 2>/dev/null || {
                echo "Error parsing paths. Please check your input format."
                exit 1
            }
        fi
        
        # Validate that we have at least one path
        if [ ${#paths[@]} -eq 0 ]; then
            echo "No valid paths found in input."
            exit 1
        fi
        
        echo "Found ${#paths[@]} path(s) to process:"
        for path in "${paths[@]}"; do
            echo "  - $path"
        done
        echo ""
        
        # Process each path
        for path in "${paths[@]}"; do
            process_path "$path"
        done
        
        echo "All paths processed."
        exit 0
    fi
    
    # Handle numeric choice (original behavior)
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "Invalid input. Please enter a number or a valid file/folder path."
        exit 1
    fi
    
    if [ "$choice" -lt 0 ] || [ "$choice" -gt "${#operations[@]}" ]; then
        echo "Invalid choice. Please enter a number between 0 and ${#operations[@]}."
        exit 1
    fi
    if [ "$choice" -eq 0 ]; then
        echo "Exiting..."
        exit 0
    fi
    IFS='|' read -r name _ <<<"${operations[$((choice - 1))]}"
    operation="$name"
    echo "Selected operation: $operation"
fi

echo "All online IPs queued: $target_ips"

# Loop through each online target IP and execute the operation
for target_ip in $target_ips; do
    ip=$target_ip
    # Skip if target IP is the same as current device IP (shouldn't happen, but safety check)
    if [ "$ip" = "$CURRENT_IP" ]; then
        echo "Skipping $ip (matches current device IP)"
        continue
    fi
    
    echo "Processing $ip..."
    
    # Get server environment (we know it's online, so this should work)
    SERVER_ENVIRONMENT=$($CURL -s --connect-timeout 5 "http://$ip:3000/api/environment" | $JQ -r '.environment' 2>/dev/null)
    if [ -z "$SERVER_ENVIRONMENT" ] || [ "$SERVER_ENVIRONMENT" = "null" ]; then
        echo "Warning: Could not determine environment for IP $ip, using 'unknown'"
        SERVER_ENVIRONMENT="unknown"
    fi
    
    execute_operation "$operation" "$ip" "$SERVER_ENVIRONMENT"
done
