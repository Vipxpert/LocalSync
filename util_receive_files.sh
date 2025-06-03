#!/bin/bash

# Change to script's directory
#cd "$(dirname "$0")"

# Assign parameters
ip="$1"
ENVIRONMENT="$2"
SERVER_ENVIRONMENT="$3"
file_time_offset="$4"
android_path="$5"
windows_path="$6"
shift 6      # Shift past the first three arguments to get files
files=("$@") # Remaining arguments are file names
base_url="http://$ip:3000/files"


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

# Normalize slashes
folder=${folder//\\//}
custom_path=${custom_path//\\//}

# Ensure temp directory exists and set permissions
mkdir -p "$temp_dir"
if [ "$ENVIRONMENT" = "termux" ]; then
    su -c "chmod 777 '$temp_dir'" || {
        echo "Error: Failed to set permissions on $temp_dir"
        exit 1
    }
else
    chmod 777 "$temp_dir" || {
        echo "Error: Failed to set permissions on $temp_dir"
        exit 1
    }
fi

# Function to download and replace file if non-empty
download_and_replace() {
    local file="$1"
    local file_name="$2"
    local temp_file="$temp_dir/$(basename "$file").temp"
    local timestamp=0

    # Extract the base file name and directory path
    local base_file_name=$(basename "$file_name")
    local dir_path=$(dirname "$file_name")

    # Construct the custom path for the query parameter
    local full_custom_path="$custom_path/$dir_path"
    full_custom_path=${full_custom_path//\\//}

    if [ -f "$file" ]; then
        if [ "$ENVIRONMENT" = "termux" ]; then
            timestamp=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
        else
            timestamp=$(stat -c %Y "$file" 2>/dev/null || date -r "$file" +%s)
        fi
    fi

    # Construct the URL with just the base file name
    local url="$base_url/$base_file_name?custom_path=$full_custom_path&time=$timestamp"

    timestamp=$((timestamp + $file_time_offset))
    local curl_exit_code=0
    USE_SU=0

    if [ "$ENVIRONMENT" = "termux" ] && command -v su >/dev/null 2>&1; then
        USE_SU=1
    fi

    # ANSI color codes
    RED='\e[31m'
    GREEN='\e[32m'
    YELLOW='\e[33m'
    CYAN='\e[36m'
    RESET='\e[0m'

    # Attempt curl command with retries
    http_code=0
    for attempt in {1..3}; do
        if [ "$ENVIRONMENT" = "termux" ]; then
            if [ "$USE_SU" -eq 1 ]; then
                response=$(su -c "/data/data/com.termux/files/usr/bin/curl -s --fail -w '%{http_code}' '$url' -o '$temp_file'" 2>/dev/null)
                curl_exit_code=$?
            else
                response=$(/data/data/com.termux/files/usr/bin/curl -s --fail -w '%{http_code}' "$url" -o "$temp_file" 2>/dev/null)
                curl_exit_code=$?
            fi
        else
            response=$(curl -s --fail -w '%{http_code}' "$url" -o "$temp_file" 2>/dev/null)
            curl_exit_code=$?
        fi
        http_code=${response: -3}
        response_body=${response%???}
        if [ $curl_exit_code -eq 0 ]; then
            if [ "$http_code" -eq 200 ]; then
                echo -e "${GREEN}$response_body${RESET}"
                break
            elif [ "$http_code" -eq 404 ]; then
                echo -e "${YELLOW}Received HTTP 404 for $file, skipping retries and keeping original file${RESET}"
                [ -f "$temp_file" ] && {
                    [ "$USE_SU" -eq 1 ] && su -c "rm -f '$temp_file'" || rm -f "$temp_file"
                }
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

    if [ $curl_exit_code -eq 0 ] && [ "$http_code" -eq 200 ] && [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        file_size=$(stat -c %s "$temp_file" 2>/dev/null || stat -f %z "$temp_file" 2>/dev/null)
        if [ -n "$file_size" ] && [ "$file_size" -gt 0 ]; then
            mkdir -p "$(dirname "$file")"
            if [ "$USE_SU" -eq 1 ]; then
                su -c "mv '$temp_file' '$file'" || {
                    echo -e "${RED}Error: Failed to move $temp_file to $file${RESET}"
                    su -c "rm -f '$temp_file'"
                    return 1
                }
            else
                mv "$temp_file" "$file" || {
                    echo -e "${RED}Error: Failed to move $temp_file to $file${RESET}"
                    rm -f "$temp_file"
                    return 1
                }
            fi
            echo -e "${GREEN}Downloaded $file to $custom_path (size: $file_size bytes)${RESET}"
        else
            echo -e "${YELLOW}Downloaded file for $file is empty or stat failed, keeping original file${RESET}"
            [ "$USE_SU" -eq 1 ] && su -c "rm -f '$temp_file'" || rm -f "$temp_file"
        fi
    else
        [ -f "$temp_file" ] && {
            [ "$USE_SU" -eq 1 ] && su -c "rm -f '$temp_file'" || rm -f "$temp_file"
        }
        if [ "$http_code" -eq 204 ]; then
            echo -e "${YELLOW}Server file is older for $file, keeping original file${RESET}"
        else
            echo -e "${RED}Failed to download $file to $custom_path after 3 attempts (HTTP code: $http_code)${RESET}"
        fi
    fi
}

# Process each file in the list
for file_name in "${files[@]}"; do
    file="$folder/$file_name"
    download_and_replace "$file" "$file_name"
done
