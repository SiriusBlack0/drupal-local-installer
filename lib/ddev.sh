#!/usr/bin/env bash

# DDEV: projects that run in containers (Docker) instead of the system's
# PHP-FPM, Nginx and database. The files of lib/ddev/, in order.

# shellcheck source=lib/ddev/checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/ddev/checks.sh"
# shellcheck source=lib/ddev/sources.sh
source "$(dirname "${BASH_SOURCE[0]}")/ddev/sources.sh"
# shellcheck source=lib/ddev/setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/ddev/setup.sh"
# shellcheck source=lib/ddev/project.sh
source "$(dirname "${BASH_SOURCE[0]}")/ddev/project.sh"
