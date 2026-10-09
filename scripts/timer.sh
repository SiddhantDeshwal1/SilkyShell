#!/usr/bin/env bash
# timer.sh — Waybar timer + stopwatch with a full terminal TUI

# ─── State directory ──────────────────────────────────────────────────────────
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/waybar-timer"
mkdir -p "$STATE_DIR"

# ─── Colour palette (shared with todo.sh) ────────────────────────────────────
FZF_COLORS="bg:#000000,bg+:#111111,\
fg:#cccccc,fg+:#ffffff,\
border:#334466,label:#6699cc,\
prompt:#9966cc,pointer:#cc4466,\
marker:#44aa66,header:#555555,\
hl:#cc4466,hl+:#ff6688,\
info:#444444,separator:#222222,scrollbar:#222222"

# ─── Low-level I/O ────────────────────────────────────────────────────────────
read_int() {
    local file="$STATE_DIR/$1"
    local val
    [[ -f "$file" ]] || { echo 0; return; }
    read -r val < "$file"
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo 0
}

read_mode() {
    local file="$STATE_DIR/mode" val
    [[ -f "$file" ]] && { read -r val < "$file"; [[ -n "$val" ]] && echo "$val" && return; }
    echo "timer"
}

write_state() { printf '%s\n' "$2" > "$STATE_DIR/$1"; }

# ─── Time helpers ─────────────────────────────────────────────────────────────
now_ms()  { date +%s%3N; }

fmt_hms() {
    local t=$1; (( t < 0 )) && t=0
    printf "%02d:%02d:%02d" $(( t/3600 )) $(( (t%3600)/60 )) $(( t%60 ))
}

fmt_ms() {
    local ms=$1; (( ms < 0 )) && ms=0
    local sec=$(( ms/1000 )) frac=$(( ms%1000 ))
    printf "%02d:%02d:%02d.%03d" $(( sec/3600 )) $(( (sec%3600)/60 )) $(( sec%60 )) "$frac"
}

fmt_overtime() {
    local t=$1; (( t < 0 )) && t=0
    printf "%02d:%02d" $(( t/60 )) $(( t%60 ))
}

# ─── Current value ────────────────────────────────────────────────────────────
current_value() {
    local mode running
    mode=$(read_mode); running=$(read_int "run")
    if [[ "$mode" == "timer" ]]; then
        if (( running == 1 )); then
            echo $(( $(read_int "duration") - (EPOCHSECONDS - $(read_int "start")) ))
        else
            read_int "remaining"
        fi
    else
        if (( running == 1 )); then
            echo $(( $(now_ms) - $(read_int "start") ))
        else
            read_int "elapsed"
        fi
    fi
}

# ─── Waybar output ────────────────────────────────────────────────────────────
cmd_output() {
    local mode val reset
    mode=$(read_mode); val=$(current_value); reset=$(read_int "reset_flag")

    if [[ "$mode" == "timer" ]]; then
        if (( val <= 0 && reset != 1 )); then
            local overtime=$(( -val ))
            local notif_flag="$STATE_DIR/notif_sent"
            if (( overtime < 2 )) && [[ ! -f "$notif_flag" ]]; then
                touch "$notif_flag"
                command -v notify-send &>/dev/null && \
                    notify-send -u critical "⏰ Timer up!" "Waybar timer has expired." &
            fi
            printf "⏰ TU: %s\n" "$(fmt_overtime "$overtime")"
        else
            rm -f "$STATE_DIR/notif_sent"
            printf "󰥔 %s\n" "$(fmt_hms "$val")"
        fi
    else
        printf "󰥔 %s\n" "$(fmt_ms "$val")"
    fi
}

# ─── Toggle (start/pause) ─────────────────────────────────────────────────────
cmd_toggle() {
    local mode running
    mode=$(read_mode); running=$(read_int "run")

    if (( running == 1 )); then
        if [[ "$mode" == "timer" ]]; then
            local rem=$(( $(read_int "duration") - (EPOCHSECONDS - $(read_int "start")) ))
            (( rem < 0 )) && rem=0
            write_state "remaining" "$rem"
        else
            local elapsed=$(( $(now_ms) - $(read_int "start") ))
            (( elapsed < 0 )) && elapsed=0
            write_state "elapsed" "$elapsed"
        fi
        write_state "run" "0"; write_state "start" "0"
    else
        rm -f "$STATE_DIR/reset_flag"
        if [[ "$mode" == "timer" ]]; then
            local rem; rem=$(read_int "remaining")
            (( rem <= 0 )) && return
            write_state "duration" "$rem"
            write_state "start"    "$EPOCHSECONDS"
            rm -f "$STATE_DIR/remaining"
        else
            local elapsed ms
            elapsed=$(read_int "elapsed"); ms=$(now_ms)
            if (( elapsed == 0 )); then
                write_state "start" "$ms"
            else
                write_state "start" "$(( ms - elapsed ))"
            fi
            rm -f "$STATE_DIR/elapsed"
        fi
        write_state "run" "1"
    fi
}

# ─── Set a timer (seconds) ────────────────────────────────────────────────────
_set_timer() {
    local sec=$1
    rm -f "$STATE_DIR/notif_sent"
    write_state "mode"       "timer"
    write_state "run"        "0"
    write_state "start"      "0"
    write_state "duration"   "$sec"
    write_state "remaining"  "$sec"
    write_state "elapsed"    "0"
    write_state "reset_flag" "0"
}

# ─── Divider helper ───────────────────────────────────────────────────────────
divider() {
    printf "ACTION:DIV_%s\t\033[2m  %-60s\033[0m\n" "$1" \
        "────────────────────────────────────────────────────────────"
}

# ─── Build live status line ───────────────────────────────────────────────────
_status_line() {
    local mode running val reset
    mode=$(read_mode); running=$(read_int "run")
    val=$(current_value); reset=$(read_int "reset_flag")

    local mode_label run_label time_str colour

    [[ "$mode" == "timer" ]] && mode_label="TIMER" || mode_label="STOPWATCH"

    if   (( running == 1 )); then run_label="\033[1;32m▶  Running\033[0m"
    else                          run_label="\033[1;33m⏸  Paused\033[0m"
    fi

    if [[ "$mode" == "timer" ]]; then
        if (( val <= 0 && reset != 1 )); then
            local ot=$(( -val ))
            time_str="\033[1;31m⏰  TIME UP  +$(fmt_overtime "$ot")\033[0m"
        elif (( reset == 1 )); then
            time_str="\033[2m  00:00:00\033[0m"
        else
            time_str="\033[1;37m  $(fmt_hms "$val")\033[0m"
        fi
    else
        time_str="\033[1;37m  $(fmt_ms "$val")\033[0m"
    fi

    printf "  %b  ·  %b  ·  %b" "$mode_label" "$run_label" "$time_str"
}

# ─── Terminal TUI ─────────────────────────────────────────────────────────────
show_tui() {
    while true; do
        local mode running status_str
        mode=$(read_mode); running=$(read_int "run")

        # Toggle label
        local toggle_label
        (( running == 1 )) \
            && toggle_label="\033[1;33m  ⏸   Pause\033[0m" \
            || toggle_label="\033[1;32m  ▶   Start / Resume\033[0m"

        local tmp_result
        tmp_result=$(mktemp /tmp/timer_fzf.XXXXXX)

        {
            # ── Control actions ────────────────────────────────────────────
            printf "ACTION:TOGGLE\t%b\n"       "$toggle_label"
            printf "ACTION:RESET\t\033[1;31m  ↺   Reset\033[0m\n"

            # ── Timer presets ──────────────────────────────────────────────
            divider "T1"
            printf "ACTION:HDR_TIMER\t  \033[1;37m SET TIMER\033[0m\n"
            divider "T2"
            printf "ACTION:T1\t  \033[0;37m  1 min\033[0m\n"
            printf "ACTION:T5\t  \033[0;37m  5 min\033[0m\n"
            printf "ACTION:T10\t  \033[0;37m  10 min\033[0m\n"
            printf "ACTION:T25\t  \033[0;37m  25 min  \033[2m(Pomodoro)\033[0m\n"
            printf "ACTION:T45\t  \033[0;37m  45 min\033[0m\n"
            printf "ACTION:CUSTOM\t  \033[1;35m  Custom…\033[0m\n"

            # ── Mode switch ────────────────────────────────────────────────
            divider "M1"
            printf "ACTION:HDR_MODE\t  \033[1;37m MODE\033[0m\n"
            divider "M2"
            if [[ "$mode" == "timer" ]]; then
                printf "ACTION:SW_TIMER\t  \033[34m◆\033[0m  Timer  \033[2m(active)\033[0m\n"
                printf "ACTION:SW_STOP\t  \033[2m◇  Stopwatch\033[0m\n"
            else
                printf "ACTION:SW_TIMER\t  \033[2m◇  Timer\033[0m\n"
                printf "ACTION:SW_STOP\t  \033[34m◆\033[0m  Stopwatch  \033[2m(active)\033[0m\n"
            fi

        } | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --border=rounded \
            --border-label="  󰥔  TIMER  ·  $(_status_line)  " \
            --border-label-pos=3 \
            --prompt="  ❯  " \
            --delimiter=$'\t' \
            --with-nth=2 \
            --nth=2 \
            --color="$FZF_COLORS" \
            --header=$'  \033[1menter\033[0m  select    \033[1mt\033[0m  toggle start/pause    \033[1mr\033[0m  reset    \033[1mq\033[0m  quit\n' \
            --expect=t,r,q,esc \
            --no-multi \
            --margin=1,3 \
            --padding=0,1 \
            > "$tmp_result"

        local exit_code=$?
        local key selection raw_tag
        key=$(head -1 "$tmp_result")
        selection=$(tail -n +2 "$tmp_result")
        raw_tag=$(printf '%s' "$selection" | cut -d$'\t' -f1)
        rm -f "$tmp_result"

        # ── Quit ──────────────────────────────────────────────────────────
        if [[ "$key" == "esc" || "$key" == "q" ]] || \
           [[ $exit_code -ne 0 && -z "$key" ]]; then
            break
        fi

        # ── Custom timer prompt ────────────────────────────────────────────
        _prompt_custom() {
            clear
            printf "\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n"
            printf "  \033[1;35m  Custom Timer\033[0m\n"
            printf "  \033[2mEnter duration, e.g.  \033[1m90\033[0;2m  (mins)  or  \033[1m1:30\033[0;2m  (h:mm)\033[0m\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n\n"
            local input
            read -e -p "  ❯  " input
            printf "\n"
            [[ -z "$input" ]] && return
            local sec
            if [[ "$input" =~ ^([0-9]+):([0-9]{2})$ ]]; then
                sec=$(( BASH_REMATCH[1]*3600 + BASH_REMATCH[2]*60 ))
            elif [[ "$input" =~ ^[1-9][0-9]*$ ]]; then
                sec=$(( input * 60 ))
            else
                printf "  \033[1;31mInvalid format.\033[0m  Use minutes (e.g. 90) or h:mm (e.g. 1:30)\n\n"
                sleep 1.5
                return
            fi
            _set_timer "$sec"
        }

        # ── Shortcut keys ──────────────────────────────────────────────────
        case "$key" in
            t) cmd_toggle; continue ;;
            r)
                rm -f "$STATE_DIR/notif_sent"
                write_state "mode"       "timer"
                write_state "run"        "0"
                write_state "start"      "0"
                write_state "duration"   "0"
                write_state "remaining"  "0"
                write_state "elapsed"    "0"
                write_state "reset_flag" "1"
                continue
                ;;
        esac

        # ── Enter on selection ─────────────────────────────────────────────
        case "$raw_tag" in
            ACTION:TOGGLE) cmd_toggle ;;
            ACTION:RESET)
                rm -f "$STATE_DIR/notif_sent"
                write_state "mode"       "timer"
                write_state "run"        "0"
                write_state "start"      "0"
                write_state "duration"   "0"
                write_state "remaining"  "0"
                write_state "elapsed"    "0"
                write_state "reset_flag" "1"
                ;;
            ACTION:T1)     _set_timer 60   ;;
            ACTION:T5)     _set_timer 300  ;;
            ACTION:T10)    _set_timer 600  ;;
            ACTION:T25)    _set_timer 1500 ;;
            ACTION:T45)    _set_timer 2700 ;;
            ACTION:CUSTOM) _prompt_custom  ;;
            ACTION:SW_TIMER)
                write_state "mode" "timer"
                write_state "run"  "0"
                write_state "reset_flag" "1"
                ;;
            ACTION:SW_STOP)
                write_state "mode"       "stopwatch"
                write_state "run"        "0"
                write_state "elapsed"    "0"
                write_state "reset_flag" "0"
                ;;
            ACTION:*) continue ;;  # headers/dividers
        esac
    done
}

# ─── Routing ──────────────────────────────────────────────────────────────────
case "$1" in
    output) cmd_output ;;
    toggle) cmd_toggle ;;
    menu)
        foot --app-id=timer-input -e bash "$0" tui
        ;;
    tui)
        show_tui
        ;;
    *)
        printf 'Usage: %s {output|toggle|menu}\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
