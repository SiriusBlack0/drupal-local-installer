#!/usr/bin/env bash

# Questions about the Drupal administrator password.

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/ui.sh

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Runs configure_admin_account with the given input and prints the
# resulting variables after the questions.
run_admin_questions() {
    printf '%b' "$1" | (
        configure_admin_account > /dev/null
        printf 'generated=%s password=%s\n' "$ADMIN_PASSWORD_GENERATED" "$ADMIN_PASSWORD"
    )
}

# Test 1: Random password: 20 letters and digits, different every time.

first="$(run_admin_questions '1\n')"
second="$(run_admin_questions '1\n')"

if [[ "$first" =~ ^generated=1\ password=[A-Za-z0-9]{20}$ ]] && [[ "$first" != "$second" ]]; then
    pass "Random password: 20 letters and digits, new each time"
else
    fail "random password: $first / $second"
fi

# Test 2: Own password, with spaces and symbols kept exactly.

result="$(run_admin_questions '2\nMy own pa$$ word!\nMy own pa$$ word!\n')"

if [[ "$result" == 'generated=0 password=My own pa$$ word!' ]]; then
    pass "Own password kept exactly (spaces and symbols)"
else
    fail "own password: $result"
fi

result="$(run_admin_questions '2\n  edge spaces  \n  edge spaces  \n')"

if [[ "$result" == 'generated=0 password=  edge spaces  ' ]]; then
    pass "Leading and trailing spaces are kept"
else
    fail "edge spaces: [$result]"
fi

# Test 3: Too short and mismatched passwords are asked again.

output="$(printf '2\nshort\nlongenough1\ndifferent1\nlongenough1\nlongenough1\n' | configure_admin_account 2>&1)"

if [[ "$output" == *"Use at least 8 characters."* && "$output" == *"Passwords do not match."* ]] &&
   [[ "$(run_admin_questions '2\nshort\nlongenough1\ndifferent1\nlongenough1\nlongenough1\n')" == "generated=0 password=longenough1" ]]; then
    pass "Short and mismatched passwords are asked again"
else
    fail "retry: $output"
fi

# Test 4: Invalid menu choice is asked again.

if [[ "$(printf '9\n1\n' | configure_admin_account)" == *"Invalid selection."* ]]; then
    pass "Invalid choice is asked again"
else
    fail "invalid choice"
fi

# Test 5: The password is never echoed to the screen.

output="$(printf '2\nSecretWord99\nSecretWord99\n' | configure_admin_account 2>&1)"

if [[ "$output" != *"SecretWord99"* ]]; then
    pass "Typed password is not shown"
else
    fail "password echoed"
fi

# Test 6: End of input cancels cleanly.

if output="$(configure_admin_account < /dev/null)" && [[ "$output" == *"Input cancelled."* ]] &&
   output="$(printf '2\n' | configure_admin_account)" && [[ "$output" == *"Input cancelled."* ]]; then
    pass "EOF cancels cleanly"
else
    fail "EOF: $output"
fi

echo "[SUCCESS] Administrator account tests passed."
