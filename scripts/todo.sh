#!/usr/bin/env bash

# ─── Paths ────────────────────────────────────────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_FILE="$DIR/tasks.txt"
SORT_FILE="$DIR/todo_sort.txt"

mkdir -p "$DIR"
touch "$TASK_FILE"

[[ -f "$SORT_FILE" ]] || echo "priority" > "$SORT_FILE"
SORT_MODE=$(cat "$SORT_FILE")

WAYBAR_SIGNAL=9

# ─── Migration ────────────────────────────────────────────────────────────────
if grep -q "^[0-9]\+|" "$TASK_FILE" 2>/dev/null; then
    sed -i -E 's/^([0-9]+\|)/A|\1/' "$TASK_FILE"
fi
if grep -qP "^[AD]\|[0-9]+\|(?!\d{2}/\d{2} \d{2}:\d{2}\|)" "$TASK_FILE" 2>/dev/null; then
    sed -i -E 's/^([AD]\|[0-9]+\|)([^|].*)$/\1??\/??\ ??:??|\2/' "$TASK_FILE"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
cleanup_tasks() {
    grep "^A|" "$TASK_FILE" >  "${TASK_FILE}.tmp" || true
    grep "^D|" "$TASK_FILE" | tail -n 5 >> "${TASK_FILE}.tmp" || true
    mv "${TASK_FILE}.tmp" "$TASK_FILE"
}

get_todo_class() {
    local count=$1
    if   [[ "$count" -eq 0 ]]; then echo "todo-none"
    elif [[ "$count" -lt 3 ]]; then echo "todo-low"
    elif [[ "$count" -lt 5 ]]; then echo "todo-medium"
    else                            echo "todo-high"
    fi
}

sort_active() {
    if [[ "$SORT_MODE" == "time" ]]; then
        sort -t'|' -k3
    else
        sort -t'|' -k2 -nr
    fi
}

# ─── Waybar status (JSON) ─────────────────────────────────────────────────────
print_waybar_status() {
    local count=0
    local tooltip="No tasks! You're all caught up. 🎉"

    if [[ -s "$TASK_FILE" ]]; then
        count=$(grep -c "^A|" "$TASK_FILE" || true)

        local active_tt
        active_tt=$(grep "^A|" "$TASK_FILE" | sort_active | \
            awk -F'|' '{print "<span color=\"#89b4fa\">[" $3 "]</span> " $4}')

        local done_tt
        done_tt=$(grep "^D|" "$TASK_FILE" | \
            awk -F'|' '{print "<span color=\"#585b70\"><s>[" $3 "] " $4 "</s></span>"}')

        if   [[ -n "$active_tt" && -n "$done_tt" ]]; then tooltip="${active_tt}\n${done_tt}"
        elif [[ -n "$active_tt" ]];                  then tooltip="${active_tt}"
        elif [[ -n "$done_tt"   ]];                  then tooltip="${done_tt}"
        fi
    fi

    jq -n -c --unbuffered \
        --arg text    "$count" \
        --arg tooltip "$tooltip" \
        --arg class   "$(get_todo_class "$count")" \
        '{"text": $text, "tooltip": $tooltip, "class": $class}'
}

# ─── Add a task ───────────────────────────────────────────────────────────────
add_task() {
    local input="$1"
    local stripped="${input// /}"
    [[ -z "$stripped" ]] && return

    local prio=10 task_text="$input"
    local re="^(.*[^[:space:]])[[:space:]]*\[([0-9]+)\]$"
    if [[ "$input" =~ $re ]]; then
        task_text="${BASH_REMATCH[1]}"
        prio="${BASH_REMATCH[2]}"
    fi

    local dt; dt=$(date "+%d/%m %H:%M")
    echo "A|${prio}|${dt}|${task_text}" >> "$TASK_FILE"
}

# ─── Colour palette (black bg) ────────────────────────────────────────────────
#   bg      = pure black
#   bg+     = very dark grey (selected row)
#   fg      = soft white
#   border  = dim blue
#   label   = bright blue
#   prompt  = lilac
#   pointer = red-pink
#   header  = dim grey
#   hl      = pink
FZF_COLORS="bg:#000000,bg+:#111111,\
fg:#cccccc,fg+:#ffffff,\
border:#334466,label:#6699cc,\
prompt:#9966cc,pointer:#cc4466,\
marker:#44aa66,header:#555555,\
hl:#cc4466,hl+:#ff6688,\
info:#444444,separator:#222222,scrollbar:#222222"

# ─── Draw a divider line ──────────────────────────────────────────────────────
divider() {
    printf "ACTION:DIV_%s\t\033[2m  %-60s\033[0m\n" "$1" "────────────────────────────────────────────────────────────"
}

# ─── Interactive TUI ──────────────────────────────────────────────────────────
show_tui() {
    while true; do
        local count sort_label active_count done_count
        active_count=$(grep -c "^A|" "$TASK_FILE" 2>/dev/null || echo 0)
        done_count=$(grep   -c "^D|" "$TASK_FILE" 2>/dev/null || echo 0)
        count=$active_count

        [[ "$SORT_MODE" == "time" ]] \
            && sort_label="Time  ⏱" \
            || sort_label="Priority  ★"

        local tmp_result
        tmp_result=$(mktemp /tmp/todo_fzf.XXXXXX)

        {
            # ── Actions block ──────────────────────────────────────────────
            printf "ACTION:ADD\t\033[1;35m  ＋  Add new task\033[0m\n"
            printf "ACTION:SORT\t\033[1;33m  ⇅   Sort: %s\033[0m\n" "$sort_label"
            printf "ACTION:CLEAR\t\033[1;31m  ✕   Clear all tasks\033[0m\n"

            # ── Active tasks block ─────────────────────────────────────────
            local has_active=false
            while IFS='|' read -r status prio dt text; do
                if [[ "$has_active" == false ]]; then
                    divider "A1"
                    printf "ACTION:HDR_ACTIVE\t  \033[1;37m ACTIVE\033[0m  \033[2m(%s)\033[0m\n" "$active_count"
                    divider "A2"
                    has_active=true
                fi
                # Priority colour: high=red, mid=yellow, low=white
                local pcolor
                if   (( prio >= 15 )); then pcolor="\033[1;31m"
                elif (( prio >= 8  )); then pcolor="\033[1;33m"
                else                        pcolor="\033[0;37m"
                fi
                printf "ACTIVE:%s|%s|%s\t  \033[34m◆\033[0m  %b%-42s\033[0m  \033[2m%s\033[0m  \033[2m[%s]\033[0m\n" \
                    "$prio" "$dt" "$text" "$pcolor" "$text" "$dt" "$prio"
            done < <(grep "^A|" "$TASK_FILE" | sort_active | \
                     awk -F'|' '{print $1"|"$2"|"$3"|"$4}')

            if [[ "$has_active" == false ]]; then
                divider "A1"
                printf "ACTION:EMPTY\t  \033[2m  No active tasks — you're all caught up 🎉\033[0m\n"
            fi

            # ── Done tasks block ───────────────────────────────────────────
            if (( done_count > 0 )); then
                divider "D1"
                printf "ACTION:HDR_DONE\t  \033[1;37m DONE\033[0m  \033[2m(%s)\033[0m\n" "$done_count"
                divider "D2"
                while IFS='|' read -r status prio dt text; do
                    printf "DONE:%s|%s|%s\t  \033[32m✓\033[0m  \033[2;9m%-42s\033[0m  \033[2m%s\033[0m\n" \
                        "$prio" "$dt" "$text" "$text" "$dt"
                done < <(grep "^D|" "$TASK_FILE" | \
                         awk -F'|' '{print $1"|"$2"|"$3"|"$4}')
            fi

        } | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --border=rounded \
            --border-label="  󰄳  TODO  ·  ${count} active  " \
            --border-label-pos=3 \
            --prompt="  ❯  " \
            --delimiter=$'\t' \
            --with-nth=2 \
            --nth=2 \
            --color="$FZF_COLORS" \
            --header=$'  \033[1menter\033[0m  toggle/delete    \033[1ma\033[0m  add    \033[1ms\033[0m  sort    \033[1mc\033[0m  clear    \033[1mq\033[0m  quit\n' \
            --expect=a,s,c,q,esc \
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

        # ── Inline prompts ─────────────────────────────────────────────────
        _do_add() {
            clear
            printf "\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n"
            printf "  \033[1;35m󰏫  New Task\033[0m\n"
            printf "  \033[2mAppend \033[1m[1–99]\033[0;2m to set priority  ·  empty to cancel\033[0m\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n\n"
            local new_task
            read -e -p "  ❯  " new_task
            printf "\n"
            add_task "$new_task"
        }

        _do_sort() {
            if [[ "$SORT_MODE" == "priority" ]]; then
                echo "time"     > "$SORT_FILE"; SORT_MODE="time"
            else
                echo "priority" > "$SORT_FILE"; SORT_MODE="priority"
            fi
        }

        _do_clear() {
            clear
            printf "\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n"
            printf "  \033[1;31m✕  Clear ALL tasks?\033[0m\n"
            printf "  \033[2mThis cannot be undone.\033[0m\n"
            printf "  \033[2m────────────────────────────────────────────────\033[0m\n\n"
            printf "  \033[1m y\033[0m  to confirm,  any other key to cancel\n\n"
            local confirm
            read -r -n1 confirm
            printf "\n"
            [[ "$confirm" == [yY] ]] && > "$TASK_FILE"
        }

        # ── Shortcut keys ─────────────────────────────────────────────────
        case "$key" in
            a) _do_add;   continue ;;
            s) _do_sort;  continue ;;
            c) _do_clear; continue ;;
        esac

        # ── Enter on selection ─────────────────────────────────────────────
        case "$raw_tag" in
            ACTION:ADD)   _do_add   ;;
            ACTION:SORT)  _do_sort  ;;
            ACTION:CLEAR) _do_clear ;;
            ACTION:*)     continue  ;;   # headers/dividers — loop again

            ACTIVE:*)
                local data="${raw_tag#ACTIVE:}"
                local prio dt text
                prio=$(cut -d'|' -f1 <<< "$data")
                dt=$(cut   -d'|' -f2 <<< "$data")
                text=$(cut -d'|' -f3- <<< "$data")
                local full="A|${prio}|${dt}|${text}"
                if grep -qF "$full" "$TASK_FILE"; then
                    grep -vF "$full" "$TASK_FILE" > "${TASK_FILE}.tmp"
                    echo "D|${prio}|${dt}|${text}" >> "${TASK_FILE}.tmp"
                    mv "${TASK_FILE}.tmp" "$TASK_FILE"
                fi
                ;;

            DONE:*)
                local data="${raw_tag#DONE:}"
                local prio dt text
                prio=$(cut -d'|' -f1 <<< "$data")
                dt=$(cut   -d'|' -f2 <<< "$data")
                text=$(cut -d'|' -f3- <<< "$data")
                local full="D|${prio}|${dt}|${text}"
                if grep -qF "$full" "$TASK_FILE"; then
                    grep -vF "$full" "$TASK_FILE" > "${TASK_FILE}.tmp"
                    mv "${TASK_FILE}.tmp" "$TASK_FILE"
                fi
                ;;
        esac

        cleanup_tasks
        pkill -RTMIN+"$WAYBAR_SIGNAL" waybar 2>/dev/null
    done

    cleanup_tasks
    pkill -RTMIN+"$WAYBAR_SIGNAL" waybar 2>/dev/null
}

# ─── Routing ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    --menu)
        foot --app-id=todo-input -e bash "$0" --tui
        ;;
    --tui)
        show_tui
        ;;
    *)
        print_waybar_status
        ;;
esac
