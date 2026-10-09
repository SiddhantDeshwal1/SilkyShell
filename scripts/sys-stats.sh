#!/usr/bin/env bash
# sys-stats.sh — unified system stats for SysStats.qml
# Outputs: cpu line from /proc/stat, MemTotal/MemAvailable from /proc/meminfo, GPU busy%
# Replaces the inline sh -c chain to avoid multiple shell/process forks.
head -1 /proc/stat
grep -E '^Mem(Total|Available):' /proc/meminfo
f=/sys/class/drm/card1/device/gpu_busy_percent
[ -f "$f" ] && printf 'G:%s%%\n' "$(cat "$f")" || echo 'G: N/A'
