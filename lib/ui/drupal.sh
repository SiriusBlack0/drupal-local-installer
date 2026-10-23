#!/usr/bin/env bash

# Phase 1: choosing the Drupal version.

# --------------------------------------------------

# Drupal version selection
# --------------------------------------------------

read_drupal_input() {
    local prompt="$1"
    local variable="$2"
    local input

    if ! IFS= read -r -p "$prompt" input; then
        echo "Input cancelled."
        exit 0
    fi

    printf -v "$variable" '%s' "$input"
}

select_drupal_latest() {
    echo

    echo "Detecting latest Drupal version..."


    DRUPAL_VERSION="$(

        get_drupal_versions 11 | head -n 1

    )"


    if [ -z "$DRUPAL_VERSION" ]; then

        echo "Could not determine latest Drupal version."

        exit 1

    fi
}

select_drupal_major_minor_patch() {
    # ------------------------------------------

    # Major version

    # ------------------------------------------


    while true; do


        echo

        echo "Select Drupal major version:"

        echo

        echo "1) Drupal 11"

        echo "2) Drupal 10"

        echo


        read_drupal_input "Select [1-2]: " DRUPAL_CHOICE


        case "$DRUPAL_CHOICE" in

            1)

                DRUPAL_MAJOR="11"

                break

                ;;

            2)

                DRUPAL_MAJOR="10"

                break

                ;;

            *)

                echo "Invalid selection. Please choose 1 or 2."

                ;;

        esac


    done


    # ------------------------------------------

    # Minor version

    # ------------------------------------------


    mapfile -t DRUPAL_MINORS < <(

        get_drupal_minor_versions "$DRUPAL_MAJOR"

    )


    if [ "${#DRUPAL_MINORS[@]}" -eq 0 ]; then

        echo "No Drupal releases found."

        exit 1

    fi


    while true; do


        echo

        echo "Available Drupal $DRUPAL_MAJOR releases:"

        echo


        for i in "${!DRUPAL_MINORS[@]}"; do

            echo "$((i + 1))) ${DRUPAL_MINORS[$i]}"

        done


        echo

        read_drupal_input "Select release: " MINOR_CHOICE


        if ! [[ "$MINOR_CHOICE" =~ ^[0-9]+$ ]] ||

           (( MINOR_CHOICE < 1 ||

              MINOR_CHOICE > ${#DRUPAL_MINORS[@]} )); then


            echo "Invalid selection. Try again."

            continue


        fi


        DRUPAL_MINOR="${DRUPAL_MINORS[$((MINOR_CHOICE - 1))]}"

        break


    done


    # ------------------------------------------

    # Patch version

    # ------------------------------------------


    mapfile -t DRUPAL_PATCHES < <(

        get_drupal_versions "$DRUPAL_MAJOR" |

        grep "^${DRUPAL_MINOR}\\."

    )


    if [ "${#DRUPAL_PATCHES[@]}" -eq 0 ]; then

        echo "No patch releases found for Drupal $DRUPAL_MINOR."

        exit 1

    fi


    while true; do


        echo

        echo "Available Drupal $DRUPAL_MINOR versions:"

        echo


        # Newest first; each version once, the newest marked.
        for i in "${!DRUPAL_PATCHES[@]}"; do

            if [ "$i" -eq 0 ]; then
                echo "$((i + 1))) ${DRUPAL_PATCHES[$i]} (latest)"
            else
                echo "$((i + 1))) ${DRUPAL_PATCHES[$i]}"
            fi

        done


        echo

        read_drupal_input "Select version: " PATCH_CHOICE


        if ! [[ "$PATCH_CHOICE" =~ ^[0-9]+$ ]]; then

            echo "Invalid selection. Try again."

            continue

        fi


        if (( PATCH_CHOICE >= 1 &&

                PATCH_CHOICE <= ${#DRUPAL_PATCHES[@]} )); then


            DRUPAL_VERSION="${DRUPAL_PATCHES[$((PATCH_CHOICE - 1))]}"

            break


        else


            echo "Invalid selection. Try again."


        fi


    done
}

select_drupal_exact() {
    while true; do


        echo

        read_drupal_input "Enter Drupal version (example 11.0.11): " DRUPAL_VERSION


        if ! [[ "$DRUPAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

            echo "Invalid Drupal version format."

            continue

        fi


        echo

        echo "Checking Drupal $DRUPAL_VERSION..."


        if drupal_version_exists "$DRUPAL_VERSION"; then

            echo "Drupal $DRUPAL_VERSION exists."

            break

        fi


        echo "Drupal $DRUPAL_VERSION does not exist."


    done
}

prompt_drupal_version() {
    while true; do


        echo

        echo "Select Drupal version:"

        echo

        echo "1) Latest stable"

        echo "2) Choose major / minor / patch"

        echo "3) Enter exact version"

        echo


        read_drupal_input "Select [1-3]: " VERSION_MODE


        case "$VERSION_MODE" in


            1)
                select_drupal_latest
                break
                ;;

            2)
                select_drupal_major_minor_patch
                break
                ;;

            3)
                select_drupal_exact
                break
                ;;

            *)

                echo "Invalid selection. Please choose 1, 2 or 3."

                ;;


        esac


    done
}
