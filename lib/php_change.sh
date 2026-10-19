#!/usr/bin/env bash

# Changing the PHP version of a project (--php NAME VERSION): lib/php_change/.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/php_change/pool.sh
source "$(dirname "${BASH_SOURCE[0]}")/php_change/pool.sh"
# shellcheck source=lib/php_change/launchers.sh
source "$(dirname "${BASH_SOURCE[0]}")/php_change/launchers.sh"
# shellcheck source=lib/php_change/checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/php_change/checks.sh"
# shellcheck source=lib/php_change/php_change.sh
source "$(dirname "${BASH_SOURCE[0]}")/php_change/php_change.sh"
