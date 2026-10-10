#!/usr/bin/env bash

# ==================================================

# PHASE 1 — CONFIGURATION

# ==================================================



# --------------------------------------------------
# Project name
# --------------------------------------------------

prompt_project_name() {
    PROJECT_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9 _-]*$'

    while true; do

        if ! read -r -p "Project name: " PROJECT_NAME; then
            echo "Input cancelled."
            exit 0
        fi

        if [ -z "$PROJECT_NAME" ]; then
            echo "Project name cannot be empty."
            continue
        fi

        if ! [[ "$PROJECT_NAME" =~ $PROJECT_NAME_PATTERN ]]; then
            echo "Invalid project name."
            echo "Use Latin letters, numbers, spaces, underscores or hyphens."
            echo "The name must start with a letter or number."
            continue
        fi

        break

    done

    PROJECT_MACHINE_NAME="$(get_project_machine_name "$PROJECT_NAME")"
}

prompt_project_name


# --------------------------------------------------

# Drupal version selection

# --------------------------------------------------



while true; do



    echo

    echo "Select Drupal version:"

    echo

    echo "1) Latest stable"

    echo "2) Choose major / minor / patch"

    echo "3) Enter exact version"

    echo



    read -r -p "Select [1-3]: " VERSION_MODE



    case "$VERSION_MODE" in



        1)

            echo

            echo "Detecting latest Drupal version..."



            DRUPAL_VERSION="$(

                get_drupal_versions 11 | head -n 1

            )"



            if [ -z "$DRUPAL_VERSION" ]; then

                echo "Could not determine latest Drupal version."

                exit 1

            fi



            break

            ;;





        2)

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



                read -r -p "Select [1-2]: " DRUPAL_CHOICE



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

                read -r -p "Select release: " MINOR_CHOICE



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



                echo "1) Latest (${DRUPAL_PATCHES[0]})"



                for i in "${!DRUPAL_PATCHES[@]}"; do

                    echo "$((i + 2))) ${DRUPAL_PATCHES[$i]}"

                done



                echo

                read -r -p "Select version: " PATCH_CHOICE



                if ! [[ "$PATCH_CHOICE" =~ ^[0-9]+$ ]]; then

                    echo "Invalid selection. Try again."

                    continue

                fi



                if [ "$PATCH_CHOICE" -eq 1 ]; then



                    DRUPAL_VERSION="${DRUPAL_PATCHES[0]}"

                    break



                elif (( PATCH_CHOICE >= 2 &&

                        PATCH_CHOICE <= ${#DRUPAL_PATCHES[@]} + 1 )); then



                    DRUPAL_VERSION="${DRUPAL_PATCHES[$((PATCH_CHOICE - 2))]}"

                    break



                else



                    echo "Invalid selection. Try again."



                fi



            done



            break

            ;;





        3)

            while true; do



                echo

                read -r -p "Enter Drupal version (example 11.0.11): " DRUPAL_VERSION



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



            break

            ;;





        *)

            echo "Invalid selection. Please choose 1, 2 or 3."

            ;;



    esac



done





# --------------------------------------------------

# PHP compatibility

# --------------------------------------------------



echo

echo "Detecting PHP requirements..."



PHP_CONSTRAINT="$(get_drupal_php_constraint "$DRUPAL_VERSION")"



if [ -z "$PHP_CONSTRAINT" ]; then

    echo "Could not determine PHP requirements for Drupal $DRUPAL_VERSION."

    exit 1

fi



DRUPAL_MINOR="$(get_drupal_minor "$DRUPAL_VERSION")"



if has_php_support_policy "$DRUPAL_MINOR"; then



    mapfile -t PHP_VERSIONS < <(

        get_supported_php_versions "$DRUPAL_MINOR"

    )



else



    echo

    echo "WARNING:"

    echo "Drupal $DRUPAL_MINOR is not listed in the current PHP support policy."

    echo "This may be an older or unsupported Drupal release."

    echo

    echo "The installer can fall back to the Composer requirement:"

    echo "PHP $PHP_CONSTRAINT"



    while true; do



        echo

        read -r -p "Continue using Composer compatibility? [y/N]: " LEGACY_CHOICE



        case "$LEGACY_CHOICE" in

            y|Y)

                break

                ;;

            n|N|"")

                echo "Installation cancelled."

                exit 0

                ;;

            *)

                echo "Please enter y or n."

                ;;

        esac



    done



    mapfile -t PHP_VERSIONS < <(

        get_compatible_php_versions "$PHP_CONSTRAINT"

    )



fi





echo

echo "Drupal $DRUPAL_VERSION requires PHP $PHP_CONSTRAINT"



if [ "${#PHP_VERSIONS[@]}" -eq 0 ]; then

    echo

    echo "No compatible PHP-FPM version was found on this system."

    exit 1

fi





while true; do



    echo

    echo "Compatible PHP versions:"

    echo



    for i in "${!PHP_VERSIONS[@]}"; do

        php_version="${PHP_VERSIONS[$i]}"
        php_status="$(get_php_version_status "$php_version")"

        echo "$((i + 1))) PHP $php_version [$php_status]"

    done



    echo

    read -r -p "Select PHP version: " PHP_CHOICE



    if ! [[ "$PHP_CHOICE" =~ ^[0-9]+$ ]] ||

       (( PHP_CHOICE < 1 ||

          PHP_CHOICE > ${#PHP_VERSIONS[@]} )); then



        echo "Invalid selection. Try again."

        continue



    fi



    PHP_VERSION="${PHP_VERSIONS[$((PHP_CHOICE - 1))]}"
    PHP_STATUS="$(get_php_version_status "$PHP_VERSION")"

    break

done


# --------------------------------------------------

# Database compatibility

# --------------------------------------------------



echo

echo "Detecting compatible databases..."



DRUPAL_MAJOR="${DRUPAL_VERSION%%.*}"



mapfile -t DATABASE_OPTIONS < <(

    get_compatible_database_options "$DRUPAL_MAJOR"

)



if [ "${#DATABASE_OPTIONS[@]}" -eq 0 ]; then

    echo "No compatible database options were found."

    exit 1

fi





while true; do



    echo

    echo "Compatible databases:"

    echo



    for i in "${!DATABASE_OPTIONS[@]}"; do

        IFS='|' read -r engine version status <<< "${DATABASE_OPTIONS[$i]}"
        echo "$((i + 1))) $engine $version [$status]"

    done



    echo

    read -r -p "Select database: " DATABASE_CHOICE



    if ! [[ "$DATABASE_CHOICE" =~ ^[0-9]+$ ]] ||

       (( DATABASE_CHOICE < 1 ||

          DATABASE_CHOICE > ${#DATABASE_OPTIONS[@]} )); then



        echo "Invalid selection. Try again."

        continue



    fi

    IFS='|' read -r DATABASE_ENGINE DATABASE_VERSION DATABASE_STATUS <<< "${DATABASE_OPTIONS[$((DATABASE_CHOICE - 1))]}"
    
    break

done





# --------------------------------------------------

# Database installation state

#

# PHASE 1 only records whether the selected database

# engine still needs to be installed.

# No installation or conflict checks happen here.

# --------------------------------------------------



DATABASE_NEEDS_INSTALL="no"



if [ "$DATABASE_STATUS" != "installed" ]; then

    DATABASE_NEEDS_INSTALL="yes"

fi



# --------------------------------------------------

# Database name

# --------------------------------------------------



SUGGESTED_DATABASE_NAME="$(

    get_project_database_name "$PROJECT_NAME"

)"



if [ "$DATABASE_ENGINE" = "sqlite" ]; then

    DATABASE_NAME=""
    DATABASE_USER=""
    DATABASE_PASSWORD=""
    SQLITE_DATABASE_PATH="sites/default/files/.ht.sqlite"

    echo
    echo "SQLite selected."
    echo "SQLite does not require a database server, user, or password."

else

    while true; do

        echo
        echo "Database name:"
        echo
        echo "1) Use suggested name: $SUGGESTED_DATABASE_NAME"
        echo "2) Enter custom database name"
        echo

        read -r -p "Select [1-2]: " DATABASE_NAME_CHOICE

        case "$DATABASE_NAME_CHOICE" in

            1)
                DATABASE_NAME="$SUGGESTED_DATABASE_NAME"
                break
                ;;

            2)
                read -r -p "Enter database name: " DATABASE_NAME

                if ! is_valid_database_name "$DATABASE_NAME"; then
                    echo "Invalid database name."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;

            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;

        esac

    done

fi



# --------------------------------------------------

# Database user

# --------------------------------------------------



if [ "$DATABASE_ENGINE" != "sqlite" ]; then

    SUGGESTED_DATABASE_USER="$(
        get_project_database_user "$PROJECT_NAME"
    )"

    while true; do

        echo
        echo "Database user:"
        echo
        echo "1) Use suggested user: $SUGGESTED_DATABASE_USER"
        echo "2) Enter custom database user"
        echo

        read -r -p "Select [1-2]: " DATABASE_USER_CHOICE

        case "$DATABASE_USER_CHOICE" in

            1)
                DATABASE_USER="$SUGGESTED_DATABASE_USER"
                break
                ;;

            2)
                read -r -p "Enter database user: " DATABASE_USER

                if ! is_valid_database_user "$DATABASE_USER"; then
                    echo "Invalid database user."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;

            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;

        esac

    done

fi



# --------------------------------------------------

# Database password

# --------------------------------------------------


if [ "$DATABASE_ENGINE" != "sqlite" ]; then

    while true; do

        echo
        read -r -s -p "Database password: " DATABASE_PASSWORD
        echo

        # Validate the first password before asking
        # the user to type it again.

        if [ -z "$DATABASE_PASSWORD" ]; then
            echo "Database password cannot be empty."
            continue
        fi

        if ! is_valid_database_password "$DATABASE_PASSWORD"; then
            echo "Invalid database password."
            echo "Use only letters, numbers and these characters: _ @ # % + = . -"
            continue
        fi

        read -r -s -p "Confirm database password: " DATABASE_PASSWORD_CONFIRM
        echo

        if [ "$DATABASE_PASSWORD" != "$DATABASE_PASSWORD_CONFIRM" ]; then
            echo "Passwords do not match. Try again."
            continue
        fi

        break

    done

fi

# --------------------------------------------------
# Final configuration summary
# --------------------------------------------------

while true; do
    echo
    echo "======================================"
    echo "        Project configuration"
    echo "======================================"
    echo
    echo "Project:  $PROJECT_NAME"
    echo "Machine:  $PROJECT_MACHINE_NAME"
    echo "Drupal:   $DRUPAL_VERSION"
    echo "PHP:      $PHP_VERSION [$PHP_STATUS]"
    echo "Database: $DATABASE_ENGINE $DATABASE_VERSION [$DATABASE_STATUS]"

    if [ "$DATABASE_ENGINE" = "sqlite" ]; then
        echo "DB File:  $SQLITE_DATABASE_PATH"
    else
        echo "DB Name:  $DATABASE_NAME"
        echo "DB User:  $DATABASE_USER"
    fi

    echo
    echo "======================================"
    echo

    read -r -p "Proceed with installation? [Y/n]: " PROCEED_CHOICE
    case "$PROCEED_CHOICE" in
        y|Y|"")
            break
            ;;
        n|N)
            echo "Installation cancelled."
            exit 0
            ;;
        *)
            echo "Please enter y or n."
            ;;
    esac
done


