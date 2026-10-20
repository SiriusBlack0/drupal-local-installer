#!/usr/bin/env bash

# The checklist of --scan and --unregister: the keys, the typed choice
# without a terminal, and the real arrow-key list in a pseudo terminal.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/checklist.sh

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

start_list() {
    CHECKLIST_COUNT="$1"
    CHECKLIST_CURSOR=1
    CHECKLIST_MARKS=()
    local i
    for (( i = 0; i < CHECKLIST_COUNT; i++ )); do CHECKLIST_MARKS[i]=0; done
}

key() {
    local status=0
    checklist_handle_key "$1" || status=$?
    echo "$status"
}

# Test 1: Keys. Rows: 0 All, 1-3 items, 4 Continue, 5 Exit.

start_list 3
checklist_handle_key space            # item 1
checklist_handle_key down
checklist_handle_key down
checklist_handle_key enter            # item 3 (Enter on an item selects too)
checklist_collect

if [[ "${CHECKLIST_SELECTED[*]}" == "0 2" ]]; then
    pass "Space or Enter on an item selects it"
else
    fail "select: ${CHECKLIST_SELECTED[*]}"
fi

checklist_handle_key up
checklist_handle_key up
checklist_handle_key up
checklist_handle_key up               # stays on row 0
checklist_handle_key space            # All: not all selected -> all
checklist_collect
all="${CHECKLIST_SELECTED[*]}"
checklist_handle_key all              # all selected -> none
checklist_collect

if [[ "$CHECKLIST_CURSOR" -eq 0 && "$all" == "0 1 2" && "${#CHECKLIST_SELECTED[@]}" -eq 0 ]]; then
    pass "All (row or 'a'): selects all, then none; the cursor stops at the top"
else
    fail "all: cursor $CHECKLIST_CURSOR, '$all', '${CHECKLIST_SELECTED[*]}'"
fi

start_list 2
checklist_handle_key down             # row 2
checklist_handle_key down             # row 3 = Continue
continue_space="$(key space)"
continue_enter="$(key enter)"
checklist_handle_key down             # Exit
checklist_handle_key down             # stays on Exit
exit_enter="$(key enter)"
quit_key="$(key quit)"

if [[ "$continue_space" == "0" && "$continue_enter" == "10" && "$exit_enter" == "11" &&
      "$quit_key" == "11" && "$CHECKLIST_CURSOR" -eq 4 ]]; then
    pass "Enter on Continue confirms, Enter on Exit or q leaves; the cursor stops at the bottom"
else
    fail "continue/exit: $continue_space $continue_enter $exit_enter $quit_key $CHECKLIST_CURSOR"
fi

# Test 2: Without a terminal the choice is typed.

if output="$(choose_from_checklist "Pick:" alpha beta gamma < <(printf '1 3\n'); echo "SEL=${CHECKLIST_SELECTED[*]}")" &&
   [[ "$output" == *"   1) alpha"* && "$output" == *"   3) gamma"* && "$output" == *"SEL=0 2" ]]; then
    pass "Typed choice: numbers"
else
    fail "typed numbers: $output"
fi

if output="$(choose_from_checklist "Pick:" alpha beta gamma < <(printf '2-3\n'); echo "SEL=${CHECKLIST_SELECTED[*]}")" &&
   [[ "$output" == *"SEL=1 2" ]] &&
   output="$(choose_from_checklist "Pick:" alpha beta gamma < <(printf 'a\n'); echo "SEL=${CHECKLIST_SELECTED[*]}")" &&
   [[ "$output" == *"SEL=0 1 2" ]]; then
    pass "Typed choice: ranges and 'a' for all"
else
    fail "typed range/all: $output"
fi

if output="$(choose_from_checklist "Pick:" alpha beta gamma < <(printf '7\n1,2\n'); echo "SEL=${CHECKLIST_SELECTED[*]}")" &&
   [[ "$output" == *"Invalid: '7' (1-3)"* && "$output" == *"SEL=0 1" ]]; then
    pass "Typed choice: a wrong number is asked again; commas work too"
else
    fail "typed invalid: $output"
fi

status=0
printf '\n' | choose_from_checklist "Pick:" alpha beta > /dev/null || status=$?
status2=0
choose_from_checklist "Pick:" alpha beta < /dev/null > /dev/null || status2=$?

if [[ "$status" -eq 1 && "$status2" -eq 1 ]]; then
    pass "Typed choice: Enter or end of input leaves"
else
    fail "typed exit: $status $status2"
fi

# Test 3: The real list in a pseudo terminal, driven with arrow keys.

if command -v python3 > /dev/null; then
    result="$(python3 - "$PWD" <<'PY'
import os, pty, sys, time, select
root = sys.argv[1]
script = ('source "%s/lib/checklist.sh"; '
          'if choose_from_checklist "Pick:" alpha beta gamma; then echo "RESULT=${CHECKLIST_SELECTED[*]}"; '
          'else echo "RESULT=exit"; fi') % root

def run(keys):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm"
        os.execvp("bash", ["bash", "--norc", "-c", script])
    out = b""
    def drain(t):
        nonlocal out
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    out += os.read(fd, 4096)
                except OSError:
                    return
    drain(0.5)
    for k in keys:
        os.write(fd, k)
        drain(0.15)
    drain(0.5)
    os.waitpid(pid, 0)
    text = out.decode(errors="replace")
    return [l for l in text.splitlines() if "RESULT=" in l][-1].split("RESULT=")[-1].strip()

down, up, space, enter = b"\x1b[B", b"\x1b[A", b" ", b"\r"
# Start on alpha: select it, down to gamma, select, down to Continue.
print(run([space, down, down, space, down, enter]))
# "a" selects all; up to the top and Space on All selects none; q leaves.
print(run([b"a", up, space, b"q"]))
# Down to Exit and Enter.
print(run([down, down, down, down, enter]))
PY
)"

    if [[ "$result" == $'0 2\nexit\nexit' ]]; then
        pass "Terminal: arrows, Space, Continue; q and Exit leave without a choice"
    else
        fail "terminal list: '$result'"
    fi
else
    echo "[SKIP] python3 not installed: terminal list"
fi

echo "[SUCCESS] Checklist tests passed."
