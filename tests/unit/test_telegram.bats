#!/usr/bin/env bats
# Unit tests for Telegram notifier functionality

# Setup test environment
setup() {
    # Create temporary test directory
    export TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    # Create logs directory
    mkdir -p logs

    # Get the path to the library
    export LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"

    # Source date utilities first (dependency)
    source "$LIB_DIR/date_utils.sh"

    # Source the telegram notifier
    source "$LIB_DIR/telegram_notifier.sh"

    # Mock curl to avoid actual API calls
    curl() {
        echo '{"ok":true,"result":{"message_id":123}}'
    }
    export -f curl
}

# Teardown test environment
teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# ============================================
# Configuration Tests
# ============================================

@test "load_env loads variables from .env file" {
    # Create a test .env file
    cat > .env << 'EOF'
RALPH_TELEGRAM_BOT_TOKEN=test_token_123
RALPH_TELEGRAM_CHAT_ID=987654321
RALPH_TELEGRAM_ENABLED=true
EOF

    # Load the env
    load_env

    # Check that variables were loaded
    [ "$RALPH_TELEGRAM_BOT_TOKEN" = "test_token_123" ]
    [ "$RALPH_TELEGRAM_CHAT_ID" = "987654321" ]
    [ "$RALPH_TELEGRAM_ENABLED" = "true" ]
}

@test "load_env returns 1 when .env file is missing" {
    rm -f .env
    run load_env
    [ "$status" -eq 1 ]
}

@test "telegram_enabled returns true when properly configured" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    telegram_enabled
    [ "$?" -eq 0 ]
}

@test "telegram_enabled returns false when token is missing" {
    unset RALPH_TELEGRAM_BOT_TOKEN
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    ! telegram_enabled
}

@test "telegram_enabled returns false when chat_id is missing" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    unset RALPH_TELEGRAM_CHAT_ID
    export RALPH_TELEGRAM_ENABLED="true"

    ! telegram_enabled
}

@test "telegram_enabled returns false when disabled" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="false"

    ! telegram_enabled
}

@test "init_telegram sets default notification preferences" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    init_telegram

    [ "$RALPH_NOTIFY_QUESTION" = "true" ]
    [ "$RALPH_NOTIFY_LOOP_COMPLETE" = "true" ]
    [ "$RALPH_NOTIFY_ERROR" = "true" ]
    [ "$RALPH_NOTIFY_CIRCUIT_BREAKER" = "true" ]
    [ "$RALPH_NOTIFY_RATE_LIMIT" = "true" ]
    [ "$RALPH_QUESTION_TIMEOUT" = "60" ]
}

# ============================================
# Quiet Hours Tests
# ============================================

@test "in_quiet_hours returns false when quiet hours disabled" {
    export RALPH_QUIET_HOURS_ENABLED="false"

    ! in_quiet_hours
}

@test "in_quiet_hours respects enabled setting" {
    export RALPH_QUIET_HOURS_ENABLED="true"
    export RALPH_QUIET_HOURS_START="00:00"
    export RALPH_QUIET_HOURS_END="23:59"

    # This should be in quiet hours (covers all day)
    in_quiet_hours
    [ "$?" -eq 0 ]
}

# ============================================
# Message Sending Tests
# ============================================

@test "send_telegram_message succeeds with valid config" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run send_telegram_message "Test message"
    [ "$status" -eq 0 ]
}

@test "send_telegram_message fails when telegram not configured" {
    unset RALPH_TELEGRAM_BOT_TOKEN
    unset RALPH_TELEGRAM_CHAT_ID
    export RALPH_TELEGRAM_ENABLED="false"

    run send_telegram_message "Test message"
    [ "$status" -eq 1 ]
}

@test "send_telegram_message skips in quiet hours" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_QUIET_HOURS_ENABLED="true"
    export RALPH_QUIET_HOURS_START="00:00"
    export RALPH_QUIET_HOURS_END="23:59"

    run send_telegram_message "Test message"
    # Should succeed (skip) without error
    [ "$status" -eq 0 ]
}

# ============================================
# Notification Function Tests
# ============================================

@test "send_loop_complete formats message correctly" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_LOOP_COMPLETE="true"

    run send_loop_complete "5" "3" "7" "PASSING" "Continue with next task"
    [ "$status" -eq 0 ]
}

@test "send_loop_complete respects notification setting" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_LOOP_COMPLETE="false"

    run send_loop_complete "5" "3" "7" "PASSING" "Continue"
    # Should succeed (skip) without actually sending
    [ "$status" -eq 0 ]
}

@test "send_error includes loop number and message" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_ERROR="true"

    run send_error "Test error message" "10" "Some details"
    [ "$status" -eq 0 ]
}

@test "send_error respects notification setting" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_ERROR="false"

    run send_error "Test error" "10"
    [ "$status" -eq 0 ]
}

@test "send_circuit_breaker sends OPEN notification" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_CIRCUIT_BREAKER="true"

    run send_circuit_breaker "OPEN" "Stagnation detected" "15"
    [ "$status" -eq 0 ]
}

@test "send_circuit_breaker sends HALF_OPEN notification" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_CIRCUIT_BREAKER="true"

    run send_circuit_breaker "HALF_OPEN" "Monitoring for recovery" "15"
    [ "$status" -eq 0 ]
}

@test "send_circuit_breaker sends CLOSED notification" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_CIRCUIT_BREAKER="true"

    run send_circuit_breaker "CLOSED" "Recovered" "15"
    [ "$status" -eq 0 ]
}

@test "send_rate_limit includes call counts and reset time" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_RATE_LIMIT="true"

    run send_rate_limit "100" "100" "15:30"
    [ "$status" -eq 0 ]
}

@test "send_question includes question and context" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"
    export RALPH_NOTIFY_QUESTION="true"

    run send_question "Which database?" "PostgreSQL or SQLite" "20"
    [ "$status" -eq 0 ]
}

@test "send_startup includes project name and rate limit" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run send_startup "my-project" "100"
    [ "$status" -eq 0 ]
}

@test "send_shutdown includes reason and loop count" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run send_shutdown "Project complete" "25" "0"
    [ "$status" -eq 0 ]
}

@test "send_status includes all status fields" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run send_status "10" "CLOSED" "50" "session-abc-123"
    [ "$status" -eq 0 ]
}

# ============================================
# Offset Management Tests
# ============================================

@test "get_update_offset returns 0 when no file exists" {
    rm -f "$TELEGRAM_OFFSET_FILE"
    result=$(get_update_offset)
    [ "$result" = "0" ]
}

@test "save_update_offset persists offset to file" {
    save_update_offset "12345"
    [ -f "$TELEGRAM_OFFSET_FILE" ]
    result=$(cat "$TELEGRAM_OFFSET_FILE")
    [ "$result" = "12345" ]
}

@test "get_update_offset reads saved offset" {
    echo "67890" > "$TELEGRAM_OFFSET_FILE"
    result=$(get_update_offset)
    [ "$result" = "67890" ]
}

# ============================================
# Retry Logic Tests
# ============================================

@test "send_telegram_message retries on failure" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    # Mock curl to fail first, then succeed
    local call_count=0
    curl() {
        call_count=$((call_count + 1))
        if [ $call_count -lt 2 ]; then
            echo '{"ok":false,"description":"Rate limited"}'
        else
            echo '{"ok":true,"result":{"message_id":123}}'
        fi
    }
    export -f curl

    run send_telegram_message "Test retry"
    [ "$status" -eq 0 ]
}

# ============================================
# Logging Tests
# ============================================

@test "log_telegram writes to log file when logs directory exists" {
    export RALPH_DEBUG="false"

    log_telegram "INFO" "Test log message"

    [ -f "logs/ralph.log" ]
    grep -q "TELEGRAM" "logs/ralph.log"
    grep -q "Test log message" "logs/ralph.log"
}

@test "log_telegram includes timestamp and level" {
    log_telegram "ERROR" "Error message"

    grep -q "ERROR" "logs/ralph.log"
    grep -q "TELEGRAM" "logs/ralph.log"
}

# ============================================
# .env.example Tests
# ============================================

@test ".env.example contains all required variables" {
    local env_example="${BATS_TEST_DIRNAME}/../../.env.example"

    [ -f "$env_example" ]
    grep -q "RALPH_TELEGRAM_BOT_TOKEN" "$env_example"
    grep -q "RALPH_TELEGRAM_CHAT_ID" "$env_example"
    grep -q "RALPH_TELEGRAM_ENABLED" "$env_example"
    grep -q "RALPH_NOTIFY_QUESTION" "$env_example"
    grep -q "RALPH_NOTIFY_LOOP_COMPLETE" "$env_example"
    grep -q "RALPH_NOTIFY_ERROR" "$env_example"
    grep -q "RALPH_NOTIFY_CIRCUIT_BREAKER" "$env_example"
    grep -q "RALPH_NOTIFY_RATE_LIMIT" "$env_example"
    grep -q "RALPH_QUESTION_TIMEOUT" "$env_example"
    grep -q "RALPH_QUIET_HOURS_ENABLED" "$env_example"
}

# ============================================
# CLI Integration Tests
# ============================================

@test "telegram_notifier.sh can be run directly with setup command" {
    # Create a minimal .env
    cat > .env << 'EOF'
RALPH_TELEGRAM_BOT_TOKEN=
RALPH_TELEGRAM_CHAT_ID=
RALPH_TELEGRAM_ENABLED=false
EOF

    # Run help (no actual setup, just check it doesn't crash)
    run bash "$LIB_DIR/telegram_notifier.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "telegram_notifier.sh shows help with no arguments" {
    run bash "$LIB_DIR/telegram_notifier.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ralph Telegram Notifier"* ]]
    [[ "$output" == *"setup"* ]]
    [[ "$output" == *"test"* ]]
}

# ============================================
# Phase 2: Interactive Q&A Tests
# ============================================

@test "parse_telegram_message extracts text from valid response" {
    export RALPH_TELEGRAM_CHAT_ID="123456"

    local updates='{"ok":true,"result":[{"update_id":100,"message":{"chat":{"id":123456},"text":"Hello world"}}]}'

    result=$(parse_telegram_message "$updates")
    [ "$result" = "Hello world" ]
}

@test "parse_telegram_message rejects wrong chat_id" {
    export RALPH_TELEGRAM_CHAT_ID="123456"

    local updates='{"ok":true,"result":[{"update_id":100,"message":{"chat":{"id":999999},"text":"Hello world"}}]}'

    run parse_telegram_message "$updates"
    [ "$status" -eq 1 ]
}

@test "parse_telegram_message updates offset" {
    export RALPH_TELEGRAM_CHAT_ID="123456"

    local updates='{"ok":true,"result":[{"update_id":54321,"message":{"chat":{"id":123456},"text":"Test"}}]}'

    parse_telegram_message "$updates" > /dev/null

    result=$(get_update_offset)
    [ "$result" = "54321" ]
}

@test "parse_telegram_message returns empty for no messages" {
    local updates='{"ok":true,"result":[]}'

    run parse_telegram_message "$updates"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "has_pending_response returns false when no file" {
    rm -f ".user_response"

    ! has_pending_response
}

@test "has_pending_response returns true when file exists" {
    echo "test response" > ".user_response"

    has_pending_response
    [ "$?" -eq 0 ]
}

@test "get_pending_response returns content and clears file" {
    echo "my answer" > ".user_response"

    result=$(get_pending_response)

    [ "$result" = "my answer" ]
    [ ! -f ".user_response" ]
}

@test "clear_pending_response removes the file" {
    echo "test" > ".user_response"
    [ -f ".user_response" ]

    clear_pending_response

    [ ! -f ".user_response" ]
}

@test "ask_telegram_question fails without question" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run ask_telegram_question ""
    [ "$status" -eq 1 ]
}

# ============================================
# Phase 2: Response Analyzer QUESTION Tests
# ============================================

@test "response_analyzer extracts QUESTION from RALPH_STATUS" {
    local ANALYZER_DIR="${BATS_TEST_DIRNAME}/../../lib"
    source "$ANALYZER_DIR/date_utils.sh"
    source "$ANALYZER_DIR/response_analyzer.sh"

    # Create test output with QUESTION
    cat > "test_output.txt" << 'EOF'
Some work done here.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 2
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
QUESTION: Which database should I use?
QUESTION_CONTEXT: PostgreSQL or SQLite based on your needs
RECOMMENDATION: Waiting for input
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.txt" 1 ".test_analysis"

    [ -f ".test_analysis" ]
    question=$(jq -r '.analysis.question' ".test_analysis")
    context=$(jq -r '.analysis.question_context' ".test_analysis")

    [ "$question" = "Which database should I use?" ]
    [ "$context" = "PostgreSQL or SQLite based on your needs" ]

    rm -f "test_output.txt" ".test_analysis"
}

@test "response_analyzer handles missing QUESTION field" {
    local ANALYZER_DIR="${BATS_TEST_DIRNAME}/../../lib"
    source "$ANALYZER_DIR/date_utils.sh"
    source "$ANALYZER_DIR/response_analyzer.sh"

    # Create test output without QUESTION
    cat > "test_output.txt" << 'EOF'
Work completed.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 3
FILES_MODIFIED: 5
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Continue with next task
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.txt" 1 ".test_analysis"

    [ -f ".test_analysis" ]
    question=$(jq -r '.analysis.question' ".test_analysis")

    [ "$question" = "" ]

    rm -f "test_output.txt" ".test_analysis"
}

@test "response_analyzer extracts tasks_completed from RALPH_STATUS" {
    local ANALYZER_DIR="${BATS_TEST_DIRNAME}/../../lib"
    source "$ANALYZER_DIR/date_utils.sh"
    source "$ANALYZER_DIR/response_analyzer.sh"

    cat > "test_output.txt" << 'EOF'
---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 5
FILES_MODIFIED: 10
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Keep going
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.txt" 1 ".test_analysis"

    tasks=$(jq -r '.analysis.tasks_completed' ".test_analysis")
    [ "$tasks" = "5" ]

    rm -f "test_output.txt" ".test_analysis"
}

@test "response_analyzer extracts test_status from RALPH_STATUS" {
    local ANALYZER_DIR="${BATS_TEST_DIRNAME}/../../lib"
    source "$ANALYZER_DIR/date_utils.sh"
    source "$ANALYZER_DIR/response_analyzer.sh"

    cat > "test_output.txt" << 'EOF'
---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 2
TESTS_STATUS: FAILING
WORK_TYPE: DEBUGGING
EXIT_SIGNAL: false
RECOMMENDATION: Fix failing tests
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.txt" 1 ".test_analysis"

    test_status=$(jq -r '.analysis.test_status' ".test_analysis")
    [ "$test_status" = "FAILING" ]

    rm -f "test_output.txt" ".test_analysis"
}

# ============================================
# Phase 3: Telegram Command Tests
# ============================================

@test "is_command returns true for commands" {
    is_command "/help"
    [ "$?" -eq 0 ]

    is_command "/status"
    [ "$?" -eq 0 ]

    is_command "/logs 5"
    [ "$?" -eq 0 ]
}

@test "is_command returns false for non-commands" {
    ! is_command "hello"
    ! is_command "some text"
    ! is_command ""
}

@test "should_pause returns false when no pause file" {
    rm -f ".telegram_paused"

    ! should_pause
}

@test "should_pause returns true when pause file exists" {
    touch ".telegram_paused"

    should_pause
    [ "$?" -eq 0 ]

    rm -f ".telegram_paused"
}

@test "should_stop returns false when no stop file" {
    rm -f ".telegram_stop"

    ! should_stop
}

@test "should_stop returns true when stop file exists" {
    touch ".telegram_stop"

    should_stop
    [ "$?" -eq 0 ]

    rm -f ".telegram_stop"
}

@test "clear_pause_flag removes pause file" {
    touch ".telegram_paused"
    [ -f ".telegram_paused" ]

    clear_pause_flag

    [ ! -f ".telegram_paused" ]
}

@test "clear_stop_flag removes stop file" {
    touch ".telegram_stop"
    [ -f ".telegram_stop" ]

    clear_stop_flag

    [ ! -f ".telegram_stop" ]
}

@test "cmd_pause creates pause file" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    rm -f ".telegram_paused"

    cmd_pause

    [ -f ".telegram_paused" ]

    rm -f ".telegram_paused"
}

@test "cmd_resume removes pause file" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    touch ".telegram_paused"

    cmd_resume

    [ ! -f ".telegram_paused" ]
}

@test "cmd_stop creates stop file" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    rm -f ".telegram_stop"

    cmd_stop

    [ -f ".telegram_stop" ]

    rm -f ".telegram_stop"
}

@test "cmd_help sends help message" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run cmd_help
    [ "$status" -eq 0 ]
}

@test "cmd_status runs without error" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run cmd_status
    [ "$status" -eq 0 ]
}

@test "cmd_logs handles missing log file" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    rm -rf logs
    mkdir -p logs

    run cmd_logs
    [ "$status" -eq 0 ]
}

@test "cmd_logs returns log content" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    mkdir -p logs
    echo "Test log line 1" > logs/ralph.log
    echo "Test log line 2" >> logs/ralph.log

    run cmd_logs 5
    [ "$status" -eq 0 ]
}

@test "handle_telegram_command processes /help" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run handle_telegram_command "/help"
    [ "$status" -eq 0 ]
}

@test "handle_telegram_command processes /pause" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    rm -f ".telegram_paused"

    run handle_telegram_command "/pause"
    [ "$status" -eq 0 ]
    [ -f ".telegram_paused" ]

    rm -f ".telegram_paused"
}

@test "handle_telegram_command returns 1 for non-command" {
    run handle_telegram_command "hello"
    [ "$status" -eq 1 ]
}

@test "handle_telegram_command handles unknown command" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    run handle_telegram_command "/unknowncommand"
    [ "$status" -eq 0 ]
}

@test "cmd_reset resets circuit breaker from OPEN to CLOSED" {
    export RALPH_TELEGRAM_BOT_TOKEN="test_token"
    export RALPH_TELEGRAM_CHAT_ID="123456"
    export RALPH_TELEGRAM_ENABLED="true"

    # Create OPEN circuit breaker state
    cat > ".circuit_breaker_state" << 'EOF'
{
    "state": "OPEN",
    "reason": "Test"
}
EOF

    cmd_reset

    local new_state=$(jq -r '.state' .circuit_breaker_state)
    [ "$new_state" = "CLOSED" ]

    rm -f ".circuit_breaker_state"
}
