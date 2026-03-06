#!/bin/bash
# Ralph Watcher — dashboard for monitoring Ralph's activity
# Usage: ./watch-ralph.sh [interval_seconds]
# Default: checks every 10 seconds
# Pair with: tail -f logs/ralph-*.log (in another tmux pane)

INTERVAL=${1:-10}
LAST_COMMIT=$(git log --oneline -1 2>/dev/null | cut -d' ' -f1)
ACTIVITY_LOG="/tmp/.ralph-watch-activity"
TICKET_TIMER="/tmp/.ralph-watch-ticket"
: > "$ACTIVITY_LOG"
touch /tmp/.ralph-watch-marker

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
ORANGE='\033[38;5;208m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Unicode fractional block elements (1/8 through 7/8)
BLOCKS=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")

# Format elapsed seconds as compact duration (e.g. "2h 14m 7s", "3d 1h 30m 12s")
fmt_duration() {
    local secs=$1
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    local out=""
    [ $d -gt 0 ] && out="${d}d "
    [ $d -gt 0 ] || [ $h -gt 0 ] && out="${out}${h}h "
    [ $d -gt 0 ] || [ $h -gt 0 ] || [ $m -gt 0 ] && out="${out}${m}m "
    out="${out}${s}s"
    echo "$out"
}

# Render a fixed-width bar using block characters
# Usage: render_bar <value> <max_value> <max_width>
# Output: bar string padded to exactly max_width visual columns
render_bar() {
    local value=$1 max_val=$2 max_width=$3
    if [ "$max_val" -eq 0 ] || [ "$value" -eq 0 ]; then
        printf '%*s' "$max_width" ""; return
    fi
    local eighths=$(( value * max_width * 8 / max_val ))
    local full=$(( eighths / 8 ))
    local frac=$(( eighths % 8 ))
    local bar=""
    for ((b=0; b<full; b++)); do bar="${bar}█"; done
    [ "$frac" -gt 0 ] && bar="${bar}${BLOCKS[$frac]}"
    local vis=$(( full + (frac > 0 ? 1 : 0) ))
    local pad=$(( max_width - vis ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%*s' "$bar" "$pad" ""
}

# Strip ANSI codes for length calculation
strip_ansi() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Get inner width (terminal width minus the two border chars)
get_inner() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    echo $(( cols - 2 ))
}

bar() {
    printf '═%.0s' $(seq 1 "$1")
}

# Print a single padded row with color support
pad_line() {
    local inner=$1
    local text="$2"
    local stripped
    stripped=$(strip_ansi "$text")
    local len=${#stripped}
    local spaces=$(( inner - len ))
    if [ "$spaces" -lt 0 ]; then spaces=0; fi
    printf "║%b%*s║\n" "$text" "$spaces" ""
}

# Print a row, truncating if too long (colors preserved)
row() {
    local inner=$1
    local label="$2"
    local label_color="$3"
    local content="$4"
    local stripped_content
    stripped_content=$(strip_ansi "$content")
    local stripped_label
    stripped_label=$(strip_ansi "$label")
    local prefix_len=$(( ${#stripped_label} + 2 ))  # label + "  "
    local max_content=$(( inner - prefix_len - 1 ))  # -1 for leading space

    # If content fits, print single line
    if [ ${#stripped_content} -le $max_content ]; then
        pad_line "$inner" " ${label_color}${stripped_label}${NC}  ${content}"
    else
        # First line: as much as fits
        local first_line="${stripped_content:0:$max_content}"
        pad_line "$inner" " ${label_color}${stripped_label}${NC}  ${first_line}"
        # Continuation lines
        local remaining="${stripped_content:$max_content}"
        local indent
        indent=$(printf '%*s' $((prefix_len + 1)) "")
        while [ -n "$remaining" ]; do
            local chunk="${remaining:0:$((inner - prefix_len - 1))}"
            remaining="${remaining:$((inner - prefix_len - 1))}"
            pad_line "$inner" "${indent}${chunk}"
        done
    fi
}

while true; do
    clear
    IW=$(get_inner)

    # Find active ralph log
    RALPH_LOG=$(ls -t logs/ralph-*.log 2>/dev/null | head -1)
    LOG_PULSE=""
    LOG_COLOR="$DIM"
    if [ -n "$RALPH_LOG" ]; then
        LOG_LINES=$(wc -l < "$RALPH_LOG" 2>/dev/null || echo 0)
        LOG_SIZE=$(du -h "$RALPH_LOG" 2>/dev/null | cut -f1 || echo "?")
        LOG_MOD=$(stat -c '%Y' "$RALPH_LOG" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        LOG_AGE=$(( NOW - LOG_MOD ))
        if [ $LOG_AGE -lt 20 ]; then
            LOG_COLOR="$GREEN"
            AGE_COLOR="$GREEN"
            LOG_PULSE="active  ${LOG_LINES} lines  ${LOG_SIZE}"
        elif [ $LOG_AGE -lt 40 ]; then
            LOG_COLOR="$YELLOW"
            AGE_COLOR="$YELLOW"
            LOG_PULSE="idle ${AGE_COLOR}(${LOG_AGE}s)${LOG_COLOR}  ${LOG_LINES} lines  ${LOG_SIZE}"
        elif [ $LOG_AGE -lt 60 ]; then
            LOG_COLOR="$DIM"
            AGE_COLOR="$ORANGE"
            LOG_PULSE="idle ${AGE_COLOR}(${LOG_AGE}s)${LOG_COLOR}  ${LOG_LINES} lines  ${LOG_SIZE}"
        else
            LOG_COLOR="$DIM"
            AGE_COLOR="$RED"
            LOG_PULSE="idle ${AGE_COLOR}(${LOG_AGE}s)${LOG_COLOR}  ${LOG_LINES} lines  ${LOG_SIZE}"
        fi
    fi

    # Gather data
    IN_PROGRESS=$(bd list --status=in_progress 2>/dev/null | head -1)
    IN_PROGRESS_PLAIN=$(strip_ansi "$IN_PROGRESS")
    LAST=$(git log --oneline -1 2>/dev/null)

    # Draw box
    printf "${DIM}╔"; bar "$IW"; printf "╗${NC}\n"
    pad_line "$IW" " ${BOLD}${CYAN}RALPH WATCHER${NC}$(printf '%*s' $((IW - 24)) '')${DIM}$(date '+%H:%M:%S')${NC} "
    printf "${DIM}╠"; bar "$IW"; printf "╣${NC}\n"

    # Track ticket timer
    TICKET_ELAPSED=""
    if [ -n "$IN_PROGRESS" ]; then
        # Extract ticket ID (first word)
        TICKET_ID=$(echo "$IN_PROGRESS_PLAIN" | awk '{print $1}')
        PREV_TICKET=""
        PREV_START=""
        if [ -f "$TICKET_TIMER" ]; then
            PREV_TICKET=$(head -1 "$TICKET_TIMER")
            PREV_START=$(tail -1 "$TICKET_TIMER")
        fi
        if [ "$TICKET_ID" != "$PREV_TICKET" ]; then
            # New ticket — reset timer
            printf '%s\n%s\n' "$TICKET_ID" "$(date +%s)" > "$TICKET_TIMER"
            PREV_START=$(date +%s)
        fi
        ELAPSED=$(( $(date +%s) - PREV_START ))
        TICKET_ELAPSED=$(fmt_duration "$ELAPSED")
        row "$IW" "TICKET" "$GREEN" "${IN_PROGRESS_PLAIN}  ${CYAN}(${TICKET_ELAPSED})${NC}"
    else
        rm -f "$TICKET_TIMER"
        row "$IW" "TICKET" "$DIM" "none in progress"
    fi

    # Last completed ticket stats (from latest log with a result line)
    LAST_DONE_LOG=$(grep -l '"type":"result"' logs/ralph-*.log 2>/dev/null | sort | tail -1)
    LAST_COST_FMT=""
    LAST_DUR_FMT=""
    if [ -n "$LAST_DONE_LOG" ]; then
        LAST_RESULT=$(grep '"type":"result"' "$LAST_DONE_LOG" 2>/dev/null)
        LAST_OUT_TOK=$(echo "$LAST_RESULT" | jq -r '.usage.output_tokens // empty' 2>/dev/null)
        LAST_DUR=$(echo "$LAST_RESULT" | jq -r '.duration_ms // empty' 2>/dev/null)
        if [ -n "$LAST_OUT_TOK" ] && [ -n "$LAST_DUR" ]; then
            LAST_DUR_FMT=$(fmt_duration $(( LAST_DUR / 1000 )))
            if [ "$LAST_OUT_TOK" -ge 1000 ]; then
                LAST_TOK_FMT="$(( LAST_OUT_TOK / 1000 ))k tok"
            else
                LAST_TOK_FMT="${LAST_OUT_TOK} tok"
            fi
        fi
    fi
    if [ -n "$LAST_TOK_FMT" ]; then
        row "$IW" "LAST" "$DIM" "${LAST}  ${YELLOW}${LAST_TOK_FMT}${NC} ${DIM}· ${LAST_DUR_FMT}${NC}"
    else
        row "$IW" "LAST" "$DIM" "$LAST"
    fi

    if [ -n "$LOG_PULSE" ]; then
        pad_line "$IW" " ${LOG_COLOR}LOG${NC}     ${LOG_COLOR}${LOG_PULSE}${NC}"
    else
        pad_line "$IW" " ${DIM}LOG     no ralph log found${NC}"
    fi

    printf "${DIM}╚"; bar "$IW"; printf "╝${NC}\n"

    # Collect histogram data from recent completed logs
    declare -a HIST_TS=() HIST_TOK=() HIST_DUR=()
    HIST_N=0; H_MAX_TOK=1; H_MAX_DUR=1
    while IFS= read -r logfile; do
        [ -z "$logfile" ] && continue
        rline=$(grep '"type":"result"' "$logfile" 2>/dev/null)
        [ -z "$rline" ] && continue
        htok=$(echo "$rline" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
        hdur=$(echo "$rline" | jq -r '.duration_ms // 0' 2>/dev/null)
        hts=$(basename "$logfile" .log | sed 's/ralph-[0-9]*-\([0-9][0-9]\)\([0-9][0-9]\).*/\1:\2/')
        HIST_TS[$HIST_N]="$hts"
        HIST_TOK[$HIST_N]="$htok"
        HIST_DUR[$HIST_N]="$hdur"
        [ "$htok" -gt "$H_MAX_TOK" ] && H_MAX_TOK="$htok"
        [ "$hdur" -gt "$H_MAX_DUR" ] && H_MAX_DUR="$hdur"
        HIST_N=$((HIST_N + 1))
    done < <(grep -l '"type":"result"' logs/ralph-*.log 2>/dev/null | sort | tail -5)

    # Draw histogram box
    if [ "$HIST_N" -gt 0 ]; then
        echo ""
        BAR_W=$(( (IW - 28) / 2 ))
        [ "$BAR_W" -gt 20 ] && BAR_W=20
        [ "$BAR_W" -lt 5 ] && BAR_W=5

        printf "${DIM}╔"; bar "$IW"; printf "╗${NC}\n"
        pad_line "$IW" " ${BOLD}SESSIONS${NC}     ${YELLOW}■ tokens${NC}  ${CYAN}■ time${NC}"
        printf "${DIM}╠"; bar "$IW"; printf "╣${NC}\n"

        for ((h=0; h<HIST_N; h++)); do
            htok="${HIST_TOK[$h]}"
            hdur="${HIST_DUR[$h]}"
            tok_bar=$(render_bar "$htok" "$H_MAX_TOK" "$BAR_W")
            dur_bar=$(render_bar "$hdur" "$H_MAX_DUR" "$BAR_W")
            if [ "$htok" -ge 1000 ]; then
                tok_v="$(( htok / 1000 ))k"
            else
                tok_v="$htok"
            fi
            tok_v=$(printf '%5s' "$tok_v")
            dur_v=$(printf '%-8s' "$(fmt_duration $(( hdur / 1000 )))")
            pad_line "$IW" " ${DIM}${HIST_TS[$h]}${NC}  ${YELLOW}${tok_bar}${NC}${DIM}${tok_v}${NC}  ${CYAN}${dur_bar}${NC} ${DIM}${dur_v}${NC}"
        done

        printf "${DIM}╚"; bar "$IW"; printf "╝${NC}\n"
    fi
    echo ""

    # Check for new commits and log them
    NEW_COMMIT=$(git log --oneline -1 2>/dev/null | cut -d' ' -f1)
    if [ "$NEW_COMMIT" != "$LAST_COMMIT" ]; then
        TS=$(date '+%H:%M:%S')
        echo -e "${GREEN}[$TS] NEW COMMIT${NC}" >> "$ACTIVITY_LOG"
        git log --oneline "$LAST_COMMIT"..HEAD 2>/dev/null | while read -r line; do
            echo -e "  ${CYAN}$line${NC}" >> "$ACTIVITY_LOG"
        done
        CHANGED=$(git diff --stat "$LAST_COMMIT"..HEAD 2>/dev/null | tail -1)
        [ -n "$CHANGED" ] && echo -e "  ${DIM}$CHANGED${NC}" >> "$ACTIVITY_LOG"
        echo "" >> "$ACTIVITY_LOG"
        LAST_COMMIT="$NEW_COMMIT"
    fi

    # Check for file modifications
    RECENT_FILES=$(find scripts/ tests/ -name "*.gd" -newer /tmp/.ralph-watch-marker 2>/dev/null | head -5)
    if [ -n "$RECENT_FILES" ]; then
        TS=$(date '+%H:%M:%S')
        echo -e "${DIM}[$TS] files modified${NC}" >> "$ACTIVITY_LOG"
        echo "$RECENT_FILES" | while read -r f; do
            echo -e "  ${DIM}$f${NC}" >> "$ACTIVITY_LOG"
        done
        echo "" >> "$ACTIVITY_LOG"
    fi
    touch /tmp/.ralph-watch-marker

    # Activity log
    if [ -s "$ACTIVITY_LOG" ]; then
        echo -e "${YELLOW}activity${NC}"
        tail -15 "$ACTIVITY_LOG" | while IFS= read -r line; do
            echo -e "  $line"
        done
    fi

    echo ""
    echo -e "${DIM}refreshing every ${INTERVAL}s · ctrl+c to stop · tail -f logs/ralph-*.log for detail${NC}"

    sleep "$INTERVAL"
done
