#!/usr/bin/env bash
# sys-stats-daemon — persistent stats daemon for SysStats.qml
# Loops forever, outputting stats block every 2 seconds separated by ---END---
# Avoids fork/exec overhead of respawning the script every cycle.

ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
MAX_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"
max_energy=0
[ -f "$MAX_ENERGY_FILE" ] && max_energy=$(< "$MAX_ENERGY_FILE")

TEMP_FILE=""
find_temp_file() {
    for h in /sys/class/hwmon/hwmon*; do
        if [ -f "$h/name" ]; then
            local n
            n=$(< "$h/name")
            if [ "$n" = "k10temp" ] && [ -f "$h/temp1_input" ]; then
                TEMP_FILE="$h/temp1_input"
                return
            fi
        fi
    done
    for h in /sys/class/hwmon/hwmon*; do
        if [ -f "$h/name" ]; then
            local n
            n=$(< "$h/name")
            if [ "$n" = "dell_smm" ] && [ -f "$h/temp1_input" ]; then
                TEMP_FILE="$h/temp1_input"
                return
            fi
        fi
    done
    for h in /sys/class/hwmon/hwmon*; do
        if [ -f "$h/temp1_input" ]; then
            TEMP_FILE="$h/temp1_input"
            return
        fi
    done
}
find_temp_file

prev_energy=""
prev_time=""
if [ -r "$ENERGY_FILE" ]; then
    prev_energy=$(< "$ENERGY_FILE")
    prev_time=${EPOCHREALTIME/./}
fi

GPU_FILE="/sys/class/drm/card1/device/gpu_busy_percent"

while true; do
    head -1 /proc/stat
    grep -E '^Mem(Total|Available):' /proc/meminfo

    if [ -f "$GPU_FILE" ]; then
        printf 'G:%s\n' "$(< "$GPU_FILE")"
    else
        echo 'G: N/A'
    fi

    # CPU Power (Wattage via RAPL)
    if [ -r "$ENERGY_FILE" ]; then
        curr_energy=$(< "$ENERGY_FILE")
        curr_time=${EPOCHREALTIME/./}
        if [ -n "$prev_energy" ] && [ -n "$prev_time" ]; then
            de=$(( curr_energy - prev_energy ))
            dt=$(( curr_time - prev_time ))
            if [ "$de" -lt 0 ] && [ "$max_energy" -gt 0 ]; then
                de=$(( de + max_energy ))
            fi
            if [ "$dt" -ge 500000 ] && [ "$de" -ge 0 ]; then
                watts=$(( (de + (dt / 2)) / dt ))
                echo "P:${watts}"
            else
                echo "P:0"
            fi
        else
            echo "P:--"
        fi
        prev_energy="$curr_energy"
        prev_time="$curr_time"
    else
        echo "P:N/A"
    fi

    # CPU Temperature
    if [ -z "$TEMP_FILE" ] || [ ! -f "$TEMP_FILE" ]; then
        find_temp_file
    fi
    if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
        raw_t=$(< "$TEMP_FILE")
        temp=$(( (raw_t + 500) / 1000 ))
        echo "T:$temp"
    else
        echo "T:N/A"
    fi

    echo '---END---'
    sleep 2
done
