#!/bin/bash

# Change to script's directory
#cd "$(dirname "$0")"

# Check for minimum required arguments
if [ $# -lt 4 ]; then
    echo "Usage: $0 <recursive> <file_time_offset> <android_path> <windows_path> [exception_file1 exception_file2 ...]"
    echo "Example: $0 true 35 '/storage/emulated/0/Vipxpert/Http' 'E:/Vipxpert' 'private/example.txt' 'logs/*.log' 'temp/*'"
    echo "recursive: 'true' for recursive processing, 'false' for top-level only"
    exit 1
fi

# Assign parameters
ip="$1"
ENVIRONMENT="$2"
SERVER_ENVIRONMENT="$3"
recursive="$4"
file_time_offset="$5"
android_path="$6"
windows_path="$7"
shift 7                         # Shift past the first four arguments to get exception files
exception_files=("$@") # Remaining arguments are exception file patterns

# Validate recursive parameter
if [ "$recursive" != "true" ] && [ "$recursive" != "false" ]; then
    echo "Error: recursive must be 'true' or 'false'"
    exit 1
fi

case "$ENVIRONMENT" in
"termux")
    JQ="/data/data/com.termux/files/usr/bin/jq"
    temp_dir="/data/data/com.termux/files/usr/tmp"
    #from
    folder="$android_path"
    ;;
"msys")
    JQ="C:/msys64/ucrt64/bin/jq.exe"
    temp_dir="/tmp"
    #from
    folder="$windows_path"
    ;;
*)
    echo "Error: Unsupported environment ($ENVIRONMENT)"
    exit 1
    ;;
esac

# Query the API endpoint
response=$(curl -s "http://$ip:3000/api/environment")
if [ $? -ne 0 ]; then
    echo "Error: Failed to connect to the server at http://$ip:3000"
    exit 1
fi

# Set temp_dir, folder (destination), and custom_path (source) based on environment
case "$SERVER_ENVIRONMENT" in
"android")
    #to
    custom_path="$android_path"
    ;;
"windows")
    #to
    custom_path="$windows_path"
    ;;
*)
    echo "Error: Unsupported environment ($SERVER_ENVIRONMENT)"
    exit 1
    ;;
esac

# Check if folder exists
if [ ! -d "$folder" ]; then
    echo "Error: Directory $folder does not exist"
    exit 1
fi

# Convert folder path to use forward slashes for consistency
folder=${folder//\\//}
custom_path=${custom_path//\\//}

# Set find command based on recursive parameter
find_cmd="find \"$folder\""
if [ "$recursive" = "false" ]; then
    find_cmd="$find_cmd -maxdepth 1"
fi
find_cmd="$find_cmd -type f"

# Loop through files in the folder (recursive or non-recursive based on parameter)
eval "$find_cmd" | while IFS= read -r file; do
    # Convert file path to use forward slashes
    file=${file//\\//}
    # Get the file name from the full path
    file_name=$(basename "$file")

    # Check if the file matches any in exception_files
    skip_file=false
    for exception in "${exception_files[@]}"; do
        if [[ "$file_name" == $exception ]]; then
            skip_file=true
            break
        fi
    done

    # Skip this file if it matches an exception
    if [ "$skip_file" = true ]; then
        echo "Skipping excluded file: $file"
        continue
    fi

    # Get the relative path by removing the base folder path
    relative_path="${file#$folder/}"
    # Get only the directory path (remove file name)
    relative_dir=$(dirname "$relative_path")
    # Construct the destination folder path (excluding file name)
    destination_path="$custom_path/$relative_dir"

    # Get file timestamp (handle differences between Termux and Git Bash)
    if [ "$ENVIRONMENT" = "termux" ]; then
        timestamp=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
    else
        timestamp=$(stat -c %Y "$file" 2>/dev/null || date -r "$file" +%s)
    fi
    timestamp=$((timestamp + $file_time_offset))
    curl_exit_code=0

    # Define a flag to enable/disable time checking (set to 1 to enable, 0 to disable)
    ENABLE_TIME_CHECK=1

    # ANSI color codes
    RED='\e[31m'
    GREEN='\e[32m'
    YELLOW='\e[33m'
    CYAN='\e[36m'
    RESET='\e[0m'

    # Time checking and upload logic
    skip_upload=0
    if [ "$ENABLE_TIME_CHECK" -eq 1 ]; then
        mtime_url="http://$ip:3000/files/mtime?custom_path=$destination_path&filename=$(basename "$file")"
        temp_response="$temp_dir/mtime_response_$$.txt"
        if [ "$ENVIRONMENT" = "termux" ]; then
            http_code=$(/data/data/com.termux/files/usr/bin/curl -s -w '%{http_code}' "$mtime_url" -o "$temp_response" 2>/dev/null)
        else
            http_code=$(curl -s -w '%{http_code}' "$mtime_url" -o "$temp_response" 2>/dev/null)
        fi
        curl_exit_code=$?

        if [ $curl_exit_code -ne 0 ]; then
            echo -e "${RED}Failed to fetch mtime (curl exit code: $curl_exit_code). Proceeding with upload.${RESET}"
            [ -f "$temp_response" ] && rm -f "$temp_response"
        else
            response_body=$(cat "$temp_response" 2>/dev/null)
            [ -f "$temp_response" ] && rm -f "$temp_response"

            if [ "$http_code" -eq 200 ] && [ -n "$response_body" ]; then
                server_mtime="$response_body"
                if [ "$(echo "$timestamp <= $server_mtime" | bc -l)" -eq 1 ]; then
                    echo -e "${YELLOW}Skipping upload of $file (server is newer or same)${RESET}"
                    skip_upload=1
                else
                    echo -e "${CYAN}Server file is older. Proceeding with upload.${RESET}"
                fi
            elif [ "$http_code" -eq 404 ]; then
                echo -e "${CYAN}File does not exist on server (HTTP 404). Proceeding with upload.${RESET}"
            else
                echo -e "${YELLOW}Server returned unexpected status ($http_code) or invalid response ($response_body). Proceeding with upload.${RESET}"
            fi
        fi
    fi

    # Upload logic with retries
    if [ $skip_upload -eq 0 ]; then
        for attempt in {1..3}; do
            if [ "$ENVIRONMENT" = "termux" ]; then
                response=$(/data/data/com.termux/files/usr/bin/curl -s --fail -w "%{http_code}" -X POST \
                    -F "file=@$file" \
                    "http://$ip:3000/upload/single?custom_path=$destination_path&time=$timestamp")
                curl_exit_code=$?
            else
                response=$(curl -s --fail -w "%{http_code}" -X POST \
                    -F "file=@$file" \
                    "http://$ip:3000/upload/single?custom_path=$destination_path&time=$timestamp")
                curl_exit_code=$?
            fi
            # Extract HTTP status code (last 3 characters) and response body
            http_code=${response: -3}
            response_body=${response%???}
            if [ $curl_exit_code -eq 0 ]; then
                if [ "$http_code" -eq 200 ]; then
                    echo -e "${GREEN}$response_body${RESET}"
                    break
                else
                    echo -e "${RED}$response_body${RESET}"
                    if [ $attempt -lt 3 ]; then
                        echo -e "${CYAN}Retrying in 1 second... (attempt $attempt)${RESET}"
                        sleep 1
                    fi
                fi
            else
                echo -e "${RED}Curl failed (exit code: $curl_exit_code)${RESET}"
                if [ $attempt -lt 3 ]; then
                    echo -e "${CYAN}Retrying in 1 second... (attempt $attempt)${RESET}"
                    sleep 1
                fi
            fi
        done

        if [ $curl_exit_code -eq 0 ] && [ "$http_code" -eq 200 ]; then
            echo -e "${GREEN}$file to $destination_path${RESET}"
        else
            echo -e "${RED}Failed to upload $file to $destination_path after 3 attempts (HTTP code: $http_code)${RESET}"
        fi
    fi
done
