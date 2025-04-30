#!/usr/bin/env bash
set -e

# Source the common functions and configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/incl.sh"

# Set the project directory if not already set
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
  log "Setting PROJECT_DIR to $PROJECT_DIR"
fi

# Get environment as parameter with default to qa
APP_ENV=${1:-qa}
TEST_ENV=APP_ENV

# Set the API key for smoke tests
# First check if it's in the environment
if [ -z "$SMOKE_TEST_API_KEY" ]; then
  # If not in environment, try to get it from the environment file
  if [ -f "$SCRIPT_DIR/env/.env.$APP_ENV" ]; then
    SMOKE_TEST_API_KEY=$(grep "SMOKE_TEST_API_KEY" "$SCRIPT_DIR/env/.env.$APP_ENV" | cut -d '=' -f2 || echo "")
  fi
  
  export SMOKE_TEST_API_KEY
fi

primary_prj=$(jq -c -r '.services[] | select(.primary == true) | if .location != null then .location else .name end' $PROJECT_DIR/services.json)
cd "$PROJECT_DIR/$primary_prj"

# Ensure that packages are installed
if [[ ! -d "$PROJECT_DIR/$primary_prj/node_modules" ]]; then

    if command -v nvm &> /dev/null
    then
      nvm use
    fi
    npm install --force
fi

# Create a log directory if it doesn't exist
LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"

# Create a timestamp-based log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/smoke_test_${APP_ENV}_${TIMESTAMP}.log"

# Configuration for retry mechanism
MAX_RETRIES=6
RETRY_DELAY=5
attempt=1
smoke_test_passed=false

# Initial delay before first attempt
log "Waiting initial ${RETRY_DELAY}s for services to initialize..."
sleep $RETRY_DELAY

while [ $attempt -le $MAX_RETRIES ]; do
    log "🔄 Smoke test attempt $attempt of $MAX_RETRIES"
    
    # Create a named pipe for capturing and processing output
    PIPE=$(mktemp -u)
    mkfifo "$PIPE"

    # Start a background process to process the output
    {
        # Run the tests and tee output to both the pipe and the log file
        npm run test:smoke:$TEST_ENV 2>&1 | tee "$LOG_FILE" > "$PIPE" &
        npm_pid=$!
        
        # Wait for the process to finish
        wait $npm_pid
        TEST_EXIT_CODE=$?
        
        # Signal to the reading process that we're done
        echo "TEST_COMPLETE:$TEST_EXIT_CODE" > "$PIPE"
    } &

    # Read from the pipe and process the output
    {
        # Initialize variables
        FAILED_TESTS=""
        ERROR_MESSAGES=""
        SUMMARY=""
        TEST_SUMMARY=""
        PROCESSING=true
        
        # Process the output line by line
        while $PROCESSING && read -r line; do
            # Check if the tests are complete
            if [[ "$line" == TEST_COMPLETE:* ]]; then
                TEST_EXIT_CODE=${line#TEST_COMPLETE:}
                PROCESSING=false
                continue
            fi
            
            # Capture PASS/FAIL test results
            if [[ "$line" == *"[PASS]"* ]]; then
                echo "  ✅ ${line#*[PASS] }"
            elif [[ "$line" == *"[FAIL]"* ]]; then
                FAILED_TESTS="$FAILED_TESTS\n  ❌ ${line#*[FAIL] }"
                # Only show failures in real-time on final attempt
                if [ $attempt -eq $MAX_RETRIES ]; then
                    echo "  ❌ ${line#*[FAIL] }"
                fi
            fi
            
            # Capture error messages
            if [[ "$line" == *"ERROR:"* ]]; then
                ERROR_MESSAGES="$ERROR_MESSAGES\n  $line"
            fi
            
            # Capture test suite summary
            if [[ "$line" == "Test Suites:"* ]]; then
                SUMMARY="$line"
            fi
            
            # Capture test summary
            if [[ "$line" == "Tests:"* ]]; then
                TEST_SUMMARY="$line"
            fi
        done < "$PIPE"
        
        # Clean up the pipe
        rm -f "$PIPE"
        
        # Only show detailed summary on final failure or success
        if [ -z "$FAILED_TESTS" ] || [ $attempt -eq $MAX_RETRIES ]; then
            log "-----------------------------------------------------------"
            log "📊 TEST SUMMARY (Attempt $attempt)"
            log "-----------------------------------------------------------"
            
            if [ -n "$SUMMARY" ]; then
                echo "  $SUMMARY"
            fi
            
            if [ -n "$TEST_SUMMARY" ]; then
                echo "  $TEST_SUMMARY"
            fi
            
            # If tests failed on final attempt, show error details
            if [ -n "$FAILED_TESTS" ] && [ $attempt -eq $MAX_RETRIES ]; then
                log "-----------------------------------------------------------"
                error "❌ FAILED TESTS:"
                echo -e "$FAILED_TESTS"
                
                if [ -n "$ERROR_MESSAGES" ]; then
                    log "-----------------------------------------------------------"
                    error "⚠️ ERROR DETAILS:"
                    echo -e "$ERROR_MESSAGES"
                fi
            fi
            
            log "-----------------------------------------------------------"
            log "Full test logs saved to: $LOG_FILE"
            log "-----------------------------------------------------------"
        fi
    } < "$PIPE"

    # Check if tests passed
    if [ -z "$FAILED_TESTS" ]; then
        log "✅ All smoke tests passed on attempt $attempt!"
        smoke_test_passed=true
        break
    else
        if [ $attempt -lt $MAX_RETRIES ]; then
            log "❌ Retrying smoke tests... (attempt $attempt of $MAX_RETRIES)"
            sleep $RETRY_DELAY
        else
            log "❌ All retry attempts exhausted."
        fi
    fi
    ((attempt++))
done

if [ "$smoke_test_passed" = true ]; then
    log "✅ Smoke tests completed successfully after $attempt attempt(s)"
    exit 0
else
    error "❌ Smoke tests failed after all $MAX_RETRIES attempts!"
    exit 1
fi 
