#!/usr/bin/env bash

# Phase 1 (configuration questions): lib/ui/, one file per topic.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/ui/project.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/project.sh"
# shellcheck source=lib/ui/drupal.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/drupal.sh"
# shellcheck source=lib/ui/php.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/php.sh"
# shellcheck source=lib/ui/database.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/database.sh"
# shellcheck source=lib/ui/admin.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/admin.sh"
# shellcheck source=lib/ui/confirm.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui/confirm.sh"
