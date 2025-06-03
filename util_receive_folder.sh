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
exception_relative_files=("$@") # Remaining arguments are exception file patterns

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
    # Get the relative path by removing the base folder path
    relative_path="${file#$folder/}"

    temp_file="$temp_dir/$(basename "$file").temp"

    # Check if the relative path matches any in exception_relative_files
    skip_file=false
    for exception in "${exception_relative_files[@]}"; do
        if [[ "$relative_path" == $exception ]]; then
            skip_file=true
            break
        fi
    done

    # Skip this file if it matches an exception
    if [ "$skip_file" = true ]; then
        echo "Skipping excluded relative path: $relative_path"
        continue
    fi

    # Get only the directory path (remove file name)
    relative_dir=$(dirname "$relative_path")
    # Construct the destination folder path (excluding file name)
    destination_path="$custom_path/$relative_dir"

    # Get file timestamp (handle differences between Termux and Git Bash)
    if [ "$ENVIRONMENT" = "termux" ]; then
        # Termux: Use stat with -c %Y
        timestamp=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
    else
        # Git Bash: Use stat with -c %Y
        timestamp=$(stat -c %Y "$file" 2>/dev/null || date -r "$file" +%s)
    fi

    timestamp=$((timestamp + $file_time_offset))
    curl_exit_code=0
    http_code=0
    # ANSI colors
    RED='\e[31m'
    GREEN='\e[32m'
    YELLOW='\e[33m'
    CYAN='\e[36m'
    RESET='\e[0m'

    if [ "$ENVIRONMENT" = "termux" ]; then
        for attempt in {1..3}; do
            response=$(/data/data/com.termux/files/usr/bin/curl -s --fail -w "%{http_code}" -X GET \
                "http://$ip:3000/files/$(basename "$file")?custom_path=$destination_path&time=$timestamp" -o "$temp_file" 2>/dev/null)
            curl_exit_code=$?
            http_code=${response: -3}
            response_body=${response%???}
            if [ $curl_exit_code -eq 0 ]; then
                if [ "$http_code" -eq 200 ]; then
                    echo -e "${GREEN}$response_body${RESET}"
                    break
                elif [ "$http_code" -eq 404 ]; then
                    echo -e "${YELLOW}Received HTTP 404 for $file, skipping retries and keeping original file${RESET}"
                    [ -f "$temp_file" ] && rm -f "$temp_file"
                    break
                elif [ "$http_code" -eq 204 ]; then
                    echo -e "${YELLOW}$response_body${RESET}"
                    break
                elif [ "$http_code" -eq 400 ] || [ "$http_code" -eq 500 ]; then
                    echo -e "${RED}$response_body${RESET}"
                    if [ $attempt -lt 3 ]; then
                        echo -e "${CYAN}Retrying in 1 second... (attempt $attempt)${RESET}"
                        sleep 1
                    fi
                else
                    echo "$response_body"
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
    else
        for attempt in {1..3}; do
            response=$(curl -s --fail -w "%{http_code}" -X GET \
                "http://$ip:3000/files/$(basename "$file")?custom_path=$destination_path&time=$timestamp" -o "$temp_file" 2>/dev/null)
            curl_exit_code=$?
            http_code=${response: -3}
            response_body=${response%???}
            if [ $curl_exit_code -eq 0 ]; then
                if [ "$http_code" -eq 200 ]; then
                    echo -e "${GREEN}$response_body${RESET}"
                    break
                elif [ "$http_code" -eq 404 ]; then
                    echo -e "${YELLOW}Received HTTP 404 for $file, skipping retries and keeping original file${RESET}"
                    [ -f "$temp_file" ] && rm -f "$temp_file"
                    break
                elif [ "$http_code" -eq 204 ]; then
                    echo -e "${YELLOW}$response_body${RESET}"
                    break
                elif [ "$http_code" -eq 400 ] || [ "$http_code" -eq 500 ]; then
                    echo -e "${RED}$response_body${RESET}"
                    if [ $attempt -lt 3 ]; then
                        echo -e "${CYAN}Retrying in 1 second... (attempt $attempt)${RESET}"
                        sleep 1
                    fi
                else
                    echo "$response_body"
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
    fi

    if [ $curl_exit_code -eq 0 ] && [ "$http_code" -eq 200 ] && [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        file_size=$(stat -c %s "$temp_file" 2>/dev/null || stat -f %z "$temp_file" 2>/dev/null)
        if [ -n "$file_size" ] && [ "$file_size" -gt 0 ]; then
            mkdir -p "$(dirname "$file")"
            mv "$temp_file" "$file" || {
                echo -e "${RED}Error: Failed to move $temp_file to $file${RESET}"
                rm -f "$temp_file"
                return 1
            }
            echo -e "${GREEN}Downloaded to $file from $destination_path (size: $file_size bytes)${RESET}"
        else
            echo -e "${YELLOW}Downloaded file for $file is empty or stat failed, keeping original file${RESET}"
            rm -f "$temp_file"
        fi
    else
        [ -f "$temp_file" ] && rm -f "$temp_file"
        if [ "$http_code" -eq 204 ]; then
            echo -e "${YELLOW}Server file is older for $file, keeping original file${RESET}"
        else
            echo -e "${RED}Failed to download to $file from $destination_path after 3 attempts (HTTP code: $http_code)${RESET}"
        fi
    fi
done
