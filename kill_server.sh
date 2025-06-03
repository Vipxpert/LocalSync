#!/bin/bash

PID=$(ps -aux | grep '[s]erver.py' | awk '{print $2}')

if [ -n "$PID" ]; then
  echo "Killing server.py with PID $PID"
  kill "$PID"
else
  echo "No server.py process found"
fi

PIDS=$(ps -aux | grep '[r]un_server.sh' | awk '{print $2}')

if [ -n "$PIDS" ]; then
  for PID in $PIDS; do
    echo "Killing run_server.sh and its child processes (PID: $PID)"
    pkill -TERM -P "$PID"   # Kill children
    kill "$PID"             # Kill the script itself
  done
else
  echo "No run_server.sh process found"
fi

PORT=3000
PID=$(lsof -i :$PORT | grep LISTEN | awk '{print $2}')

if [ -n "$PID" ]; then
  echo "Killing process on port $PORT with PID $PID"
  kill "$PID"
else
  echo "No process is listening on port $PORT"
fi