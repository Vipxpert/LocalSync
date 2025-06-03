#!/bin/bash

# Run this script with ./file_sync_operation.sh operation_name
# ex ./file_sync_operation.sh receive_database

cd "$(dirname "$0")"

# Determine bash command based on environment
TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
if [ -x "$TERMUX_BASH" ]; then
    BASH_CMD="$TERMUX_BASH"
else
    BASH_CMD="bash"
fi
ENVIRONMENT=$($BASH_CMD util_detect_env.sh)

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

# Set current device's path
if [ "$ENVIRONMENT" = "termux" ]; then
    android_current_path=$(pwd)
else
    windows_current_path=$(pwd)
fi

# Function to get target IPs from the database
get_target_ips() {
    local current_ip="$1"
    local db_file="./private/LocalSync.db"
    if [ ! -f "$db_file" ]; then
        echo "Error: Database file $db_file does not exist."
        exit 1
    fi
    $SQLITE3 "$db_file" "SELECT IPAddress FROM devices WHERE IPAddress != '$current_ip';"
}

# Retrieve target IPs
target_ips=$(get_target_ips "$CURRENT_IP")
if [ -z "$target_ips" ]; then
    echo "No other devices found in the database."
    exit 1
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
    "send_current_non_recursive|util_send_folder.sh|-35|$android_current_path|$windows_current_path|false||private/ip_target.txt,example.txt,.DS_Store,temp*,*.log"
    "send_current_recursive|util_send_folder.sh|-35|$android_current_path|$windows_current_path|true||private/ip_target.txt,example.txt,.DS_Store,temp*,*.log"
    "receive_current_non_recursive|util_receive_folder.sh|35|$android_current_path|$windows_current_path|false||private/ip_target.txt,private/example.txt,logs/*.log,temp/*"
    "receive_current_recursive|util_receive_folder.sh|35|$android_current_path|$windows_current_path|true||private/ip_target.txt,private/example.txt,logs/*.log,temp/*"
    "receive_server|util_receive_files.sh|1|$android_current_path|$windows_current_path||server.py,templates/HTML/happy_birthday/happy-birthday.html|"
    "send_database|util_send_files.sh|-1|$android_current_path|$windows_current_path||private/LocalSync.db|"
    "receive_database|util_receive_files.sh|1|$android_current_path|$windows_current_path||private/LocalSync.db|"
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
        IFS='|' read -r name _ <<< "${operations[i]}"
        echo "  $((i + 1)). $name"
    done
}

# Function to validate operation
validate_operation() {
    local op="$1"
    for o in "${operations[@]}"; do
        IFS='|' read -r name _ <<< "$o"
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
        IFS='|' read -r name script file_time_offset android_path windows_path recursive files exceptions <<< "$op"
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
    IFS='|' read -r name script file_time_offset android_path windows_path recursive files exceptions <<< "$op_data"

    # Convert comma-separated files and exceptions to arrays
    IFS=',' read -r -a files_array <<< "$files"
    IFS=',' read -r -a exceptions_array <<< "$exceptions"

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
    read -p "Enter the number of the operation to run: " choice
    if [ "$choice" -lt 0 ] || [ "$choice" -gt "${#operations[@]}" ]; then
        echo "Invalid choice. Please enter a number between 0 and ${#operations[@]}."
        exit 1
    fi
    if [ "$choice" -eq 0 ]; then
        echo "Exiting..."
        exit 0
    fi
    IFS='|' read -r name _ <<< "${operations[$((choice - 1))]}"
    operation="$name"
    echo "Selected operation: $operation"
fi

# Prompt for inputs if the operation is manual
if [[ "$operation" == *"manually"* ]]; then
    read -p "Enter android_path (default: .): " android_path
    android_path=${android_path:-.}
    read -p "Enter windows_path (default: .): " windows_path
    windows_path=${windows_path:-.}
    read -p "Enter time_offset (default: 0): " time_offset
    time_offset=${time_offset:-0}
    if [[ "$operation" == *"files_manually" ]]; then
        files=()
        echo "Enter files (one per line, enter empty line to finish):"
        while true; do
            read -p "File: " file
            if [ -z "$file" ]; then
                break
            fi
            files+=("$file")
        done
        if [ ${#files[@]} -eq 0 ]; then
            files=("server.py")
        fi
        # Update the operation in the array with correct script name
        for i in "${!operations[@]}"; do
            IFS='|' read -r name _ <<< "${operations[i]}"
            if [ "$name" = "$operation" ]; then
                if [[ "$operation" == "send_files_manually" ]]; then
                    operations[i]="$name|util_send_files.sh|$time_offset|$android_path|$windows_path||${files[*]}|"
                elif [[ "$operation" == "receive_files_manually" ]]; then
                    operations[i]="$name|util_receive_files.sh|$time_offset|$android_path|$windows_path||${files[*]}|"
                fi
                break
            fi
        done
    elif [[ "$operation" == *"folder_manually" ]]; then
        read -p "Recursive? (y/n, default: n): " recursive_input
        if [ "$recursive_input" = "y" ]; then
            recursive="true"
        else
            recursive="false"
        fi
        # Update the operation in the array with correct script name
        for i in "${!operations[@]}"; do
            IFS='|' read -r name _ <<< "${operations[i]}"
            if [ "$name" = "$operation" ]; then
                if [[ "$operation" == "send_folder_manually" ]]; then
                    operations[i]="$name|util_send_folder.sh|$time_offset|$android_path|$windows_path|$recursive||"
                elif [[ "$operation" == "receive_folder_manually" ]]; then
                    operations[i]="$name|util_receive_folder.sh|$time_offset|$android_path|$windows_path|$recursive||"
                fi
                break
            fi
        done
    fi
fi

echo "All IP queued: $target_ips"

# Loop through each target IP and execute the operation
for target_ip in $target_ips; do
    ip=$target_ip
    # Skip if target IP is the same as current device IP
    if [ "$ip" = "$CURRENT_IP" ]; then
        echo "Skipping $ip (matches current device IP)"
        continue
    fi
    echo "Processing $ip..."
    SERVER_ENVIRONMENT=$(echo $($CURL -s "http://$ip:3000/api/environment") | $JQ -r '.environment')
    if [ -z "$SERVER_ENVIRONMENT" ]; then
        echo "Error: Could not determine environment for IP $ip (connection lost or something else)"
        continue
    fi
    case "$SERVER_ENVIRONMENT" in
    "android")
        android_current_path=$($CURL -s "http://$ip:3000/get_directory" | $JQ -r '.directory')
        ;;
    "windows")
        windows_current_path=$($CURL -s "http://$ip:3000/get_directory" | $JQ -r '.directory')
        ;;
    *)
        echo "Error: Unsupported environment ($SERVER_ENVIRONMENT) for IP $ip"
        continue
        ;;
    esac
    execute_operation "$operation" "$ip" "$SERVER_ENVIRONMENT"
done