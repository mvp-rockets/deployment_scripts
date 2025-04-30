#!/usr/bin/env bash
set -e

# Source the common functions and configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/incl.sh"

# Print usage if no arguments provided
if [ $# -eq 0 ]; then
  echo "Usage: $0 <environment> [test_type]"
  echo ""
  echo "Run smoke tests for the specified environment."
  echo ""
  echo "Arguments:"
  echo "  environment  The environment to run tests against (e.g., dev, qa, uat, prod)"
  echo "  test_type    Optional: Type of test to run (all, health, auth, communications)"
  echo "               Default is 'all'"
  echo ""
  echo "Examples:"
  echo "  $0 qa                     # Run all smoke tests on QA environment"
  echo "  $0 prod communications    # Run only communication smoke tests on production"
  echo ""
  exit 1
fi

# Set the project directory if not already set
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
  log "Setting PROJECT_DIR to $PROJECT_DIR"
fi

# Separator for pretty output
log "==============================================================="
log "🔌 STARTING SMOKE TESTS FOR ENVIRONMENT: $1"
log "==============================================================="

# Execute the main smoke test script with the specified environment
# Use 'bash' explicitly to ensure it doesn't run in a subshell that might exit prematurely
bash "$SCRIPT_DIR/run-smoke-tests.sh" "$1"

# Store the result
RESULT=$?

# Print a summary
if [ $RESULT -eq 0 ]; then
  log "==============================================================="
  log "✅ SMOKE TESTS COMPLETED SUCCESSFULLY"
  log "==============================================================="
else
  error "==============================================================="
  error "❌ SMOKE TESTS FAILED - SEE DETAILS ABOVE"
  error "==============================================================="
fi

exit $RESULT 