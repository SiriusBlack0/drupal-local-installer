#!/usr/bin/env bash



set -e



SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"



source "$SCRIPT_DIR/lib/drupal.sh"
source "$SCRIPT_DIR/lib/php.sh"
source "$SCRIPT_DIR/lib/php_fpm.sh"
source "$SCRIPT_DIR/lib/nginx.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/compatibility.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/registry.sh"
source "$SCRIPT_DIR/lib/packages.sh"


# --------------------------------------------------
# Operating system compatibility
# --------------------------------------------------

echo
echo "Checking operating system..."

if is_ubuntu_system; then
    echo "[SUPPORTED] Ubuntu detected."
    get_linux_distribution
else
    echo "[UNSUPPORTED] Only Ubuntu is supported."
    exit 1
fi

echo

echo "======================================"

echo "        Drupal Local Installer"

echo "======================================"

echo






source "$SCRIPT_DIR/lib/ui.sh"

# ==================================================

# PHASE 2 — PREFLIGHT / INSTALLATION

# ==================================================


source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/plan.sh"
source "$SCRIPT_DIR/lib/install_execution.sh"
source "$SCRIPT_DIR/lib/readiness.sh"
source "$SCRIPT_DIR/lib/project.sh"
source "$SCRIPT_DIR/lib/workflow.sh"

if ! run_installation_workflow; then
    echo "[ERROR] Installation workflow failed."
    exit 1
fi

#echo

#echo "======================================"

#echo "     Preflight / Installation"

#echo "======================================"

#echo

#echo "Phase 1 configuration completed successfully."

#echo

#echo "No system changes have been made yet."

#echo "The next implementation step will add:"

#echo "  - Administrator authentication"

#echo "  - Preflight checks"

#echo "  - Database engine installation when required"

#echo "  - Database and database user provisioning"