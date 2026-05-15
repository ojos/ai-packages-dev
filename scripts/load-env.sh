#!/bin/bash

# Load environment variables from .env file if it exists
# This script enables project-specific environment variables to override remoteEnv settings.
# 
# Usage:
#   bash scripts/load-env.sh          # Execute as subprocess
#   source scripts/load-env.sh        # Source in current shell (preferred for env vars)
#
# Behavior:
#   - If .env exists in project root, source it with `set -a` to export all variables
#   - All variables in .env will override any existing environment variables (project priority)
#   - If .env does not exist, silently continue (no error)

load_env_vars() {
  if [ -f .env ]; then
    # set -a: automatically export all variable assignments
    # set +a: return to normal behavior after sourcing
    set -a
    source .env
    set +a
  fi
}

# If sourced, define and call function in current shell
# If executed as subprocess, call function and export to child
load_env_vars
