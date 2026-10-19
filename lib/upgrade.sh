#!/usr/bin/env bash

# Major upgrades of Drupal core (--upgrade NAME): lib/upgrade/.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/upgrade/checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/upgrade/checks.sh"
# shellcheck source=lib/upgrade/upgrade_status.sh
source "$(dirname "${BASH_SOURCE[0]}")/upgrade/upgrade_status.sh"
# shellcheck source=lib/upgrade/composer.sh
source "$(dirname "${BASH_SOURCE[0]}")/upgrade/composer.sh"
# shellcheck source=lib/upgrade/upgrade.sh
source "$(dirname "${BASH_SOURCE[0]}")/upgrade/upgrade.sh"
