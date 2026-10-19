#!/usr/bin/env bash

# Databases: lib/database/ has one file per engine and a common file.
# Each file only defines functions and variables; the order is fixed.

# shellcheck source=lib/database/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/database/common.sh"
# shellcheck source=lib/database/mysql.sh
source "$(dirname "${BASH_SOURCE[0]}")/database/mysql.sh"
# shellcheck source=lib/database/postgresql.sh
source "$(dirname "${BASH_SOURCE[0]}")/database/postgresql.sh"
# shellcheck source=lib/database/sqlite.sh
source "$(dirname "${BASH_SOURCE[0]}")/database/sqlite.sh"
