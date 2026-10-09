#!/bin/bash

# Using card1 based on your terminal output
GPU_PATH="/sys/class/drm/card1/device/gpu_busy_percent"

if [ -f "$GPU_PATH" ]; then
    USAGE=$(cat "$GPU_PATH")
    echo "G:$USAGE% "
else
    echo "G: N/A "
fi
