#!/usr/bin/env bash

# Phase 1: the Drupal administrator account.

# --------------------------------------------------
# Drupal administrator account
# --------------------------------------------------

# Used by lib/workflow.sh and install.sh.
# shellcheck disable=SC2034
ADMIN_USER="admin"
# shellcheck disable=SC2034
ADMIN_MAIL="admin@example.com"
ADMIN_PASSWORD=""
ADMIN_PASSWORD_GENERATED=0

# 20 letters and digits: strong, and easy to copy from the terminal.
generate_admin_password() {
    local password=""

    while [[ "${#password}" -lt 20 ]]; do
        password+="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9')"
    done

    printf '%s\n' "${password:0:20}"
}

prompt_admin_password() {
    local confirm

    while true; do
        echo

        if ! IFS= read -r -s -p "Administrator password: " ADMIN_PASSWORD; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [[ "${#ADMIN_PASSWORD}" -lt 8 ]]; then
            echo "Use at least 8 characters."
            continue
        fi

        if ! IFS= read -r -s -p "Confirm administrator password: " confirm; then
            echo
            echo "Input cancelled."
            exit 0
        fi
        echo

        if [[ "$ADMIN_PASSWORD" != "$confirm" ]]; then
            echo "Passwords do not match. Try again."
            continue
        fi

        break
    done
}

configure_admin_account() {
    local choice

    while true; do
        echo
        echo "Drupal administrator password (user: $ADMIN_USER):"
        echo
        echo "1) Generate a strong random password (shown once at the end)"
        echo "2) Enter my own password"
        echo

        if ! read -r -p "Select [1-2]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            1)
                ADMIN_PASSWORD="$(generate_admin_password)"
                ADMIN_PASSWORD_GENERATED=1
                return 0
                ;;
            2)
                prompt_admin_password
                ADMIN_PASSWORD_GENERATED=0
                return 0
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}
