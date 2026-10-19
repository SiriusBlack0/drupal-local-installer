#!/usr/bin/env bash

# System checks, services and APT: lib/system/.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/system/checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/system/checks.sh"
# shellcheck source=lib/system/services.sh
source "$(dirname "${BASH_SOURCE[0]}")/system/services.sh"
# shellcheck source=lib/system/apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/system/apt.sh"
