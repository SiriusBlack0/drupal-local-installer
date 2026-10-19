#!/usr/bin/env bash

# Updating Drupal core (--check-updates, --update NAME): lib/update/.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/update/check.sh
source "$(dirname "${BASH_SOURCE[0]}")/update/check.sh"
# shellcheck source=lib/update/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/update/backup.sh"
# shellcheck source=lib/update/snapshot.sh
source "$(dirname "${BASH_SOURCE[0]}")/update/snapshot.sh"
# shellcheck source=lib/update/advisories.sh
source "$(dirname "${BASH_SOURCE[0]}")/update/advisories.sh"
# shellcheck source=lib/update/update.sh
source "$(dirname "${BASH_SOURCE[0]}")/update/update.sh"
