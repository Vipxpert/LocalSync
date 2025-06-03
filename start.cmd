@echo off
setlocal EnableDelayedExpansion

set "MSYS_BASH_PATH=C:\msys64\usr\bin\bash.exe"
set "GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe"
set "CURRENT_DIR=%cd%"

:: Check for MSYS2 Bash
if exist "%MSYS_BASH_PATH%" (
    echo Using MSYS2 Bash...
    "%MSYS_BASH_PATH%" --login -i -c "cd '%CURRENT_DIR%' && bash 'start.sh'; echo Press any key to exit...; read -n 1 -s"
    exit /b
)

:: Fallback to Git Bash
if exist "%GIT_BASH_PATH%" (
    echo Using Git Bash...
    "%GIT_BASH_PATH%" --login -i -c "cd '%CURRENT_DIR%' && bash 'start.sh'; echo Press any key to exit...; read -n 1 -s"
    exit /b
)
python server.py
:: Neither found
echo Error: Neither MSYS2 nor Git Bash found. Please install one of them or update the paths.
pause
exit /b 1
