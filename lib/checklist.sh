#!/usr/bin/env bash

# --------------------------------------------------
# Checklist: choose several items of a list
# --------------------------------------------------
#
# In a terminal: a list with [ ] in front of each item, moved through
# with the arrow keys:
#
#   > [x] All
#     [x] crmmanager   ...
#     [ ] eventmanager ...
#         Continue (1 selected)
#         Exit, change nothing
#
# Up/Down move, Space (or Enter on an item) selects, "a" selects all or
# none, Enter on Continue confirms, Enter on Exit (or "q", Esc) leaves.
# Without a terminal (pipes, tests) the same choice is typed as numbers.
#
# choose_from_checklist "Title" "item 1" "item 2" ...
# Returns 0 with CHECKLIST_SELECTED holding the chosen indexes (0-based,
# in list order; maybe none), 1 when the user leaves.

CHECKLIST_SELECTED=()
CHECKLIST_MARKS=()
CHECKLIST_CURSOR=0
CHECKLIST_COUNT=0

# Rows: 0 = All, 1..COUNT = the items, COUNT+1 = Continue, COUNT+2 = Exit.
checklist_selected_count() {
    local mark
    local count=0

    for mark in "${CHECKLIST_MARKS[@]}"; do
        [[ "$mark" -eq 1 ]] && count=$((count + 1))
    done

    echo "$count"
}

checklist_toggle_all() {
    local value=1
    local i

    [[ "$(checklist_selected_count)" -eq "$CHECKLIST_COUNT" ]] && value=0

    for (( i = 0; i < CHECKLIST_COUNT; i++ )); do
        CHECKLIST_MARKS[i]="$value"
    done
}

# One key (up, down, space, enter, all, quit). Returns 0 to go on,
# 10 when confirmed, 11 when the user leaves.
checklist_handle_key() {
    local key="$1"
    local last=$((CHECKLIST_COUNT + 2))
    local item

    case "$key" in
        up) (( CHECKLIST_CURSOR > 0 )) && CHECKLIST_CURSOR=$((CHECKLIST_CURSOR - 1)) ;;
        down) (( CHECKLIST_CURSOR < last )) && CHECKLIST_CURSOR=$((CHECKLIST_CURSOR + 1)) ;;
        all) checklist_toggle_all ;;
        quit) return 11 ;;
        space|enter)
            if [[ "$CHECKLIST_CURSOR" -eq 0 ]]; then
                checklist_toggle_all
            elif [[ "$CHECKLIST_CURSOR" -le "$CHECKLIST_COUNT" ]]; then
                item=$((CHECKLIST_CURSOR - 1))
                CHECKLIST_MARKS[item]=$((1 - CHECKLIST_MARKS[item]))
            elif [[ "$CHECKLIST_CURSOR" -eq $((CHECKLIST_COUNT + 1)) ]]; then
                [[ "$key" == "enter" ]] && return 10
            else
                [[ "$key" == "enter" ]] && return 11
            fi
            ;;
    esac

    return 0
}

checklist_collect() {
    local i

    CHECKLIST_SELECTED=()

    for (( i = 0; i < CHECKLIST_COUNT; i++ )); do
        [[ "${CHECKLIST_MARKS[i]}" -eq 1 ]] && CHECKLIST_SELECTED+=("$i")
    done

    return 0
}

# The rows of the list, the cursor row with ">".
checklist_draw() {
    local -a items=("$@")
    local row
    local pointer
    local mark
    local all_mark=" "

    [[ "$CHECKLIST_COUNT" -gt 0 && "$(checklist_selected_count)" -eq "$CHECKLIST_COUNT" ]] && all_mark="x"

    for (( row = 0; row <= CHECKLIST_COUNT + 2; row++ )); do
        pointer=" "
        [[ "$row" -eq "$CHECKLIST_CURSOR" ]] && pointer=">"

        if [[ "$row" -eq 0 ]]; then
            printf '\r\033[K  %s [%s] All\n' "$pointer" "$all_mark"
        elif [[ "$row" -le "$CHECKLIST_COUNT" ]]; then
            mark=" "
            [[ "${CHECKLIST_MARKS[row - 1]}" -eq 1 ]] && mark="x"
            printf '\r\033[K  %s [%s] %s\n' "$pointer" "$mark" "${items[row - 1]}"
        elif [[ "$row" -eq $((CHECKLIST_COUNT + 1)) ]]; then
            printf '\r\033[K  %s     Continue (%s selected)\n' "$pointer" "$(checklist_selected_count)"
        else
            printf '\r\033[K  %s     Exit, change nothing\n' "$pointer"
        fi
    done
}

# Reads one key from the terminal and names it.
checklist_read_key() {
    local key
    local rest

    IFS= read -rsn1 key || { echo "quit"; return 0; }

    case "$key" in
        $'\e')
            IFS= read -rsn2 -t 0.05 rest || rest=""
            case "$rest" in
                '[A'|'OA') echo "up" ;;
                '[B'|'OB') echo "down" ;;
                '') echo "quit" ;;
                *) echo "other" ;;
            esac
            ;;
        ' ') echo "space" ;;
        '') echo "enter" ;;
        a|A) echo "all" ;;
        q|Q) echo "quit" ;;
        k) echo "up" ;;
        j) echo "down" ;;
        *) echo "other" ;;
    esac
}

checklist_interactive() {
    local -a items=("$@")
    local rows=$((CHECKLIST_COUNT + 3))
    local key
    local status

    echo "  (Up/Down move, Space selects, a = all, Enter on Continue confirms, q = exit)"
    printf '\033[?25l'
    # The cursor comes back even after Ctrl+C.
    trap 'printf "\033[?25h"; trap - INT; kill -INT $$' INT
    checklist_draw "${items[@]}"

    while true; do
        key="$(checklist_read_key)"
        status=0
        checklist_handle_key "$key" || status=$?

        [[ "$status" -eq 0 ]] || break

        printf '\033[%sA' "$rows"
        checklist_draw "${items[@]}"
    done

    trap - INT
    printf '\033[?25h'

    [[ "$status" -eq 10 ]] || return 1
    checklist_collect
}

# Without a terminal: numbers, ranges (2-4), "a" for all; empty or "q"
# leaves.
checklist_typed() {
    local -a items=("$@")
    local i
    local answer
    local word
    local from
    local to

    for (( i = 0; i < CHECKLIST_COUNT; i++ )); do
        printf '  %2d) %s\n' "$((i + 1))" "${items[i]}"
    done

    while true; do
        if ! read -r -p "  Numbers to select (e.g. 1 3 5 or 2-4), a = all, Enter = exit: " answer; then
            echo
            return 1
        fi

        answer="${answer//,/ }"
        [[ -n "${answer// /}" && "$answer" != "q" && "$answer" != "Q" ]] || return 1

        if [[ "$answer" == "a" || "$answer" == "A" ]]; then
            for (( i = 0; i < CHECKLIST_COUNT; i++ )); do CHECKLIST_MARKS[i]=1; done
            checklist_collect
            return 0
        fi

        for (( i = 0; i < CHECKLIST_COUNT; i++ )); do CHECKLIST_MARKS[i]=0; done

        for word in $answer; do
            if [[ "$word" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                from="${BASH_REMATCH[1]}"
                to="${BASH_REMATCH[2]}"
            elif [[ "$word" =~ ^[0-9]+$ ]]; then
                from="$word"
                to="$word"
            else
                from=0
                to=0
            fi

            if (( from < 1 || to > CHECKLIST_COUNT || from > to )); then
                echo "  Invalid: '$word' (1-$CHECKLIST_COUNT)"
                continue 2
            fi

            for (( i = from; i <= to; i++ )); do CHECKLIST_MARKS[i - 1]=1; done
        done

        checklist_collect
        return 0
    done
}

choose_from_checklist() {
    local title="$1"
    shift
    local i

    CHECKLIST_COUNT="$#"
    CHECKLIST_CURSOR=1
    CHECKLIST_MARKS=()
    CHECKLIST_SELECTED=()

    for (( i = 0; i < CHECKLIST_COUNT; i++ )); do CHECKLIST_MARKS[i]=0; done

    echo
    echo "$title"

    if [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]] &&
       [[ "$((CHECKLIST_COUNT + 6))" -le "$(tput lines 2>/dev/null || echo 24)" ]]; then
        checklist_interactive "$@"
    else
        checklist_typed "$@"
    fi
}
