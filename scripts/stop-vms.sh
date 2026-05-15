#!/bin/bash

WS=/home/xtl/cxlfork-ws

for vm in vm0 vm1; do
  if [ -f "$WS/pids/${vm}.pid" ]; then
    PID=$(cat "$WS/pids/${vm}.pid")
    kill "$PID" 2>/dev/null && echo "[$vm stopped, pid=$PID]" || echo "[$vm not running]"
    rm -f "$WS/pids/${vm}.pid"
  fi
done