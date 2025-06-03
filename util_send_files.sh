#!/bin/bash

# Change to script's directory
#cd "$(dirname "$0")"

# Check for minimum required arguments
if [ $# -lt 4 ]; then
    echo "Usage: $0 <file_time_offset> <android_path> <windows_path> <file1> [file2 ...]"
    echo "Example: $0 -60 '/storage/self/primary/Android/media/com.geode.launcher/save' 'C:/Users/Vipxpert/AppData/Local/GeometryDash' CCLocalLevels.dat CCGameManager.dat"
    exit 1
fi

# Assign parameters
ip="$1"
ENVIRONMENT="$2"
SERVER_ENVIRONMENT="$3"
file_time_offset="$4"
android_path="$5"
windows_path="$6"
shift 6      # Shift past the first three arguments to get files
files=("$@") # Remaining arguments are file names


echo "maybe $ENVIRONMENT $SERVER_ENVIRONMENT $android_path $windows_path"
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

# Convert folder and custom_path to use forward slashes for consistency
folder=${folder//\\//}
custom_path=${custom_path//\\//}

# Check if folder exists
if [ ! -d "$folder" ]; then
    echo "Error: Directory $folder does not exist"
    exit 1
fi

# Function to upload file
upload_file() {
    local file="$1"
    # Get file timestamp (handle differences between Termux and Git Bash)
    if [ "$ENVIRONMENT" = "termux" ]; then
        # Termux: Use stat with -c %Y
        timestamp=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
    else
        # Git Bash: Use stat with -c %Y
        timestamp=$(stat -c %Y "$file" 2>/dev/null || date -r "$file" +%s)
    fi

    local curl_exit_code=0
    USE_SU=0

    # Check if we are in Termux and 'su' exists
    if [ "$ENVIRONMENT" = "termux" ] && command -v su >/dev/null 2>&1; then
        USE_SU=1
    fi

    # Define a flag to enable/disable time checking (set to 1 to enable, 0 to disable)
    ENABLE_TIME_CHECK=1

    # ANSI colors
    RED='\e[31m'
    GREEN='\e[32m'
    YELLOW='\e[33m'
    CYAN='\e[36m'
    RESET='\e[0m'

    # Time check and upload
    skip_upload=0
    if [ "$ENABLE_TIME_CHECK" -eq 1 ]; then
        mtime_url="http://$ip:3000/files/mtime?custom_path=$custom_path&filename=$(basename "$file")"
        echo -e "${CYAN}Checking mtime: $mtime_url${RESET}"

        temp_response="$temp_dir/mtime_response_$$.txt"

        # Curl with/without su
        if [ "$ENVIRONMENT" = "termux" ]; then
            if [ "$USE_SU" -eq 1 ]; then
                http_code=$(su -c "/data/data/com.termux/files/usr/bin/curl -s -w '%{http_code}' '$mtime_url' -o '$temp_response'" 2>/dev/null)
            else
                http_code=$(/data/data/com.termux/files/usr/bin/curl -s -w '%{http_code}' "$mtime_url" -o "$temp_response" 2>/dev/null)
            fi
        else
            http_code=$(curl -s -w '%{http_code}' "$mtime_url" -o "$temp_response" 2>/dev/null)
        fi

        timestamp=$((timestamp + $file_time_offset))
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
                echo -e "${YELLOW}Unexpected server response: HTTP $http_code, body: $response_body. Proceeding with upload.${RESET}"
            fi
        fi
    fi

    # Upload logic with 
    if [ $skip_upload -eq 0 ]; then
        for attempt in {1..3}; do
            if [ "$ENVIRONMENT" = "termux" ]; then
                response=$(/data/data/com.termux/files/usr/bin/curl --fail -w "%{http_code}" -X POST \
                    -F "file=@$file" \
                    "http://$ip:3000/upload/single?custom_path=$custom_path&time=$timestamp")
                curl_exit_code=$?
            else
                response=$(curl --fail -w "%{http_code}" -X POST \
                    -F "file=@$file" \
                    "http://$ip:3000/upload/single?custom_path=$custom_path&time=$timestamp")
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
}

# Process each file in the list
for file_name in "${files[@]}"; do
    # Construct full file path by appending file name to folder
    file="$folder/$file_name"
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "Error: File $file does not exist"
        continue
    fi
    upload_file "$file"
done
