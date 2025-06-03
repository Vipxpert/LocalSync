#!/bin/bash

# detect_env.sh
# Function to detect the environment
detect_environment() {
    # Check if running on Termux (Android)
    if [ -n "$TERMUX_VERSION" ]; then
        echo "termux"
        return 0

    # Check if running in MSYS2 (MSYS or UCRT or CLANG)
    elif [[ "$MSYSTEM" == MSYS* || "$MSYSTEM" == UCRT64 || "$MSYSTEM" == CLANG64 ]]; then
        if ! command -v bc >/dev/null 2>&1; then
            echo "msys detected but bc isn't installed. Install bc using: pacman -S bc"
        else
            echo "msys"
        fi
        return 1

    # Check if running on Git Bash (MINGW32 or MINGW64)
    elif [[ "$MSYSTEM" == MINGW32 || "$MSYSTEM" == MINGW64 ]]; then
        echo "gitbash"
        return 2

    # Check for Linux
    elif [ "$(uname)" = "Linux" ]; then
        echo "linux"
        return 3

    # Check for macOS
    elif [ "$(uname)" = "Darwin" ]; then
        echo "macos"
        return 4

    else
        echo "unknown"
        return 5
    fi
}

# Call the function to output the environment
detect_environment
