#!/bin/bash
# Telegram Notifier Component for Ralph
# Sends notifications to Telegram for status updates, errors, and questions

# Source date utilities for timestamps
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/date_utils.sh"

# Telegram API base URL
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

# Rate limiting
TELEGRAM_MIN_INTERVAL=1  # Minimum seconds between messages
TELEGRAM_LAST_SEND=0

# State files
TELEGRAM_OFFSET_FILE=".telegram_offset"

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# CONFIGURATION
# ============================================

# Load environment variables from .env file
load_env() {
    local env_file="${1:-.env}"

    if [[ -f "$env_file" ]]; then
        # Export all variables from .env
        set -a
        source "$env_file"
        set +a
        return 0
    fi
    return 1
}

# Check if Telegram is configured and enabled
telegram_enabled() {
    [[ "${RALPH_TELEGRAM_ENABLED:-false}" == "true" ]] && \
    [[ -n "${RALPH_TELEGRAM_BOT_TOKEN:-}" ]] && \
    [[ -n "${RALPH_TELEGRAM_CHAT_ID:-}" ]]
}

# Initialize Telegram (load config and validate)
init_telegram() {
    # Load .env if not already loaded
    if [[ -z "${RALPH_TELEGRAM_BOT_TOKEN:-}" ]]; then
        load_env
    fi

    if ! telegram_enabled; then
        return 1
    fi

    # Set defaults for notification preferences
    RALPH_NOTIFY_QUESTION="${RALPH_NOTIFY_QUESTION:-true}"
    RALPH_NOTIFY_LOOP_COMPLETE="${RALPH_NOTIFY_LOOP_COMPLETE:-true}"
    RALPH_NOTIFY_ERROR="${RALPH_NOTIFY_ERROR:-true}"
    RALPH_NOTIFY_CIRCUIT_BREAKER="${RALPH_NOTIFY_CIRCUIT_BREAKER:-true}"
    RALPH_NOTIFY_RATE_LIMIT="${RALPH_NOTIFY_RATE_LIMIT:-true}"
    RALPH_QUESTION_TIMEOUT="${RALPH_QUESTION_TIMEOUT:-60}"

    return 0
}

# Check if we're in quiet hours
in_quiet_hours() {
    if [[ "${RALPH_QUIET_HOURS_ENABLED:-false}" != "true" ]]; then
        return 1  # Not in quiet hours (quiet hours disabled)
    fi

    local current_time=$(date +%H:%M)
    local start="${RALPH_QUIET_HOURS_START:-23:00}"
    local end="${RALPH_QUIET_HOURS_END:-07:00}"

    # Handle overnight quiet hours (e.g., 23:00 to 07:00)
    if [[ "$start" > "$end" ]]; then
        # Overnight period
        if [[ "$current_time" > "$start" || "$current_time" == "$start" ]] || [[ "$current_time" < "$end" ]]; then
            return 0  # In quiet hours
        fi
    else
        # Same-day period
        if [[ "$current_time" > "$start" || "$current_time" == "$start" ]] && [[ "$current_time" < "$end" ]]; then
            return 0  # In quiet hours
        fi
    fi

    return 1  # Not in quiet hours
}

# ============================================
# RATE LIMITING
# ============================================

# Apply rate limiting to prevent Telegram API abuse
rate_limit_telegram() {
    local now=$(get_epoch_seconds)
    local elapsed=$((now - TELEGRAM_LAST_SEND))

    if [[ $elapsed -lt $TELEGRAM_MIN_INTERVAL ]]; then
        sleep $((TELEGRAM_MIN_INTERVAL - elapsed))
    fi

    TELEGRAM_LAST_SEND=$(get_epoch_seconds)
}

# ============================================
# CORE SENDING FUNCTIONS
# ============================================

# Send a message to Telegram
# Usage: send_telegram_message "message" [parse_mode]
send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-Markdown}"
    local max_retries=3
    local retry=0

    if ! telegram_enabled; then
        log_telegram "WARNING" "Telegram not configured, skipping notification"
        return 1
    fi

    # Check quiet hours
    if in_quiet_hours; then
        log_telegram "INFO" "In quiet hours, skipping notification"
        return 0
    fi

    # Apply rate limiting
    rate_limit_telegram

    while [[ $retry -lt $max_retries ]]; do
        local response
        response=$(curl -s --max-time 10 \
            "${TELEGRAM_API_URL}/bot${RALPH_TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${RALPH_TELEGRAM_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=${parse_mode}" \
            2>/dev/null)

        if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
            log_telegram "INFO" "Message sent successfully"
            return 0
        fi

        local error_desc=$(echo "$response" | jq -r '.description // "Unknown error"' 2>/dev/null)
        log_telegram "WARNING" "Send failed (attempt $((retry+1))/$max_retries): $error_desc"

        ((retry++))
        sleep $((retry * 2))  # Exponential backoff
    done

    log_telegram "ERROR" "Failed to send message after $max_retries retries"
    return 1
}

# Send a message without markdown parsing (plain text)
send_telegram_plain() {
    local message="$1"
    send_telegram_message "$message" ""
}

# ============================================
# NOTIFICATION FUNCTIONS
# ============================================

# Send loop completion notification
# Usage: send_loop_complete <loop_number> <tasks_completed> <files_modified> <test_status> <remaining_tasks> <work_summary> [recommendation]
send_loop_complete() {
    local loop_number="$1"
    local tasks_completed="$2"
    local files_modified="$3"
    local test_status="$4"
    local remaining_tasks="${5:-0}"
    local work_summary="${6:-}"
    local recommendation="${7:-}"

    if [[ "${RALPH_NOTIFY_LOOP_COMPLETE:-true}" != "true" ]]; then
        return 0
    fi

    # Skip notification if no actual work was done
    if [[ "$tasks_completed" == "0" && "$files_modified" == "0" ]]; then
        log_telegram "INFO" "Skipping notification - no work done this loop"
        return 0
    fi

    local test_emoji="?"
    case "$test_status" in
        PASSING|passing) test_emoji="PASS" ;;
        FAILING|failing) test_emoji="FAIL" ;;
        NOT_RUN|not_run) test_emoji="-" ;;
    esac

    local message="*Loop #${loop_number} Complete*

Done: ${tasks_completed} tasks | ${files_modified} files
Remaining: ${remaining_tasks} tasks | Tests: ${test_emoji}"

    if [[ -n "$work_summary" ]]; then
        message+="

*Work done:*
${work_summary}"
    fi

    if [[ -n "$recommendation" ]]; then
        message+="

*Next:* ${recommendation}"
    fi

    send_telegram_message "$message"
}

# Send error notification
# Usage: send_error <error_message> <loop_number> [details]
send_error() {
    local error_message="$1"
    local loop_number="$2"
    local details="${3:-}"

    if [[ "${RALPH_NOTIFY_ERROR:-true}" != "true" ]]; then
        return 0
    fi

    local message="*Ralph Error*

Loop #${loop_number} encountered an error:
\`${error_message}\`"

    if [[ -n "$details" ]]; then
        message+="

Details: ${details}"
    fi

    send_telegram_message "$message"
}

# Send circuit breaker notification
# Usage: send_circuit_breaker <new_state> <reason> [loop_number]
send_circuit_breaker() {
    local new_state="$1"
    local reason="$2"
    local loop_number="${3:-}"

    if [[ "${RALPH_NOTIFY_CIRCUIT_BREAKER:-true}" != "true" ]]; then
        return 0
    fi

    local state_emoji=""
    local state_text=""

    case "$new_state" in
        OPEN)
            state_emoji="[STOPPED]"
            state_text="Ralph has stopped"
            ;;
        HALF_OPEN)
            state_emoji="[WARNING]"
            state_text="Ralph is monitoring for recovery"
            ;;
        CLOSED)
            state_emoji="[OK]"
            state_text="Ralph is running normally"
            ;;
    esac

    local message="${state_emoji} *Circuit Breaker: ${new_state}*

${state_text}

Reason: ${reason}"

    if [[ -n "$loop_number" ]]; then
        message+="
Loop: #${loop_number}"
    fi

    if [[ "$new_state" == "OPEN" ]]; then
        message+="

Reply /reset to reset circuit breaker"
    fi

    send_telegram_message "$message"
}

# Send rate limit notification
# Usage: send_rate_limit <calls_used> <max_calls> <reset_time>
send_rate_limit() {
    local calls_used="$1"
    local max_calls="$2"
    local reset_time="$3"

    if [[ "${RALPH_NOTIFY_RATE_LIMIT:-true}" != "true" ]]; then
        return 0
    fi

    local message="*Rate Limit Reached*

${calls_used}/${max_calls} API calls used this hour.
Resuming at: ${reset_time}

Ralph will continue automatically."

    send_telegram_message "$message"
}

# Send question notification (Phase 2 - placeholder for now)
# Usage: send_question <question> [context] [loop_number]
send_question() {
    local question="$1"
    local context="${2:-}"
    local loop_number="${3:-}"

    if [[ "${RALPH_NOTIFY_QUESTION:-true}" != "true" ]]; then
        return 0
    fi

    local message="*Ralph needs your input*

*Question:*
${question}"

    if [[ -n "$context" ]]; then
        message+="

*Context:*
${context}"
    fi

    if [[ -n "$loop_number" ]]; then
        message+="

Loop: #${loop_number}"
    fi

    message+="

Reply with your answer or /skip to let Ralph decide."

    send_telegram_message "$message"
}

# Send startup notification
# Usage: send_startup <project_name> [max_calls]
send_startup() {
    local project_name="$1"
    local max_calls="${2:-100}"

    local message="*Ralph Started*

Project: ${project_name}
Rate limit: ${max_calls} calls/hour
Time: $(get_basic_timestamp)

Notifications enabled. Reply /help for commands."

    send_telegram_message "$message"
}

# Send shutdown notification
# Usage: send_shutdown <reason> <total_loops> [exit_code]
send_shutdown() {
    local reason="$1"
    local total_loops="$2"
    local exit_code="${3:-0}"

    local status_emoji="[DONE]"
    if [[ "$exit_code" != "0" ]]; then
        status_emoji="[ERROR]"
    fi

    local message="${status_emoji} *Ralph Stopped*

Reason: ${reason}
Total loops: ${total_loops}
Exit code: ${exit_code}
Time: $(get_basic_timestamp)"

    send_telegram_message "$message"
}

# Send status summary
# Usage: send_status <loop_number> <circuit_state> <calls_remaining> <session_id>
send_status() {
    local loop_number="$1"
    local circuit_state="$2"
    local calls_remaining="$3"
    local session_id="${4:-none}"

    local circuit_emoji=""
    case "$circuit_state" in
        CLOSED) circuit_emoji="[OK]" ;;
        HALF_OPEN) circuit_emoji="[!]" ;;
        OPEN) circuit_emoji="[X]" ;;
    esac

    local message="*Ralph Status*

Loop: #${loop_number}
Circuit: ${circuit_emoji} ${circuit_state}
API calls remaining: ${calls_remaining}
Session: ${session_id:0:8}...
Time: $(get_basic_timestamp)"

    send_telegram_message "$message"
}

# ============================================
# TEST & SETUP FUNCTIONS
# ============================================

# Test Telegram connection
test_telegram_connection() {
    echo -e "${BLUE}Testing Telegram connection...${NC}"

    if [[ -z "${RALPH_TELEGRAM_BOT_TOKEN:-}" ]]; then
        echo -e "${RED}Error: RALPH_TELEGRAM_BOT_TOKEN not set${NC}"
        return 1
    fi

    if [[ -z "${RALPH_TELEGRAM_CHAT_ID:-}" ]]; then
        echo -e "${RED}Error: RALPH_TELEGRAM_CHAT_ID not set${NC}"
        return 1
    fi

    # Test bot token by getting bot info
    local bot_info
    bot_info=$(curl -s --max-time 10 \
        "${TELEGRAM_API_URL}/bot${RALPH_TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)

    if ! echo "$bot_info" | jq -e '.ok == true' > /dev/null 2>&1; then
        echo -e "${RED}Error: Invalid bot token${NC}"
        echo "Response: $bot_info"
        return 1
    fi

    local bot_name=$(echo "$bot_info" | jq -r '.result.username')
    echo -e "${GREEN}Bot found: @${bot_name}${NC}"

    # Send test message
    echo -e "${BLUE}Sending test message...${NC}"

    local test_message="*Ralph Test Message*

Your Telegram integration is working!
Time: $(get_basic_timestamp)

You will receive notifications here."

    if send_telegram_message "$test_message"; then
        echo -e "${GREEN}Test message sent successfully!${NC}"
        echo -e "${GREEN}Check your Telegram for the message.${NC}"
        return 0
    else
        echo -e "${RED}Failed to send test message${NC}"
        return 1
    fi
}

# Interactive setup for Telegram
setup_telegram() {
    echo -e "${BLUE}=== Ralph Telegram Setup ===${NC}"
    echo

    # Check if .env exists
    if [[ -f ".env" ]]; then
        echo -e "${YELLOW}Found existing .env file${NC}"
        read -p "Overwrite Telegram settings? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            echo "Setup cancelled."
            return 1
        fi
    else
        # Copy from example if available
        if [[ -f ".env.example" ]]; then
            cp .env.example .env
            echo -e "${GREEN}Created .env from .env.example${NC}"
        else
            touch .env
            echo -e "${GREEN}Created new .env file${NC}"
        fi
    fi

    echo
    echo -e "${BLUE}Step 1: Get your bot token${NC}"
    echo "  1. Open Telegram and search for @BotFather"
    echo "  2. Send /newbot and follow the prompts"
    echo "  3. Copy the token (looks like: 123456789:ABCdef...)"
    echo
    read -p "Enter your bot token: " bot_token

    if [[ -z "$bot_token" ]]; then
        echo -e "${RED}Error: Bot token is required${NC}"
        return 1
    fi

    echo
    echo -e "${BLUE}Step 2: Get your chat ID${NC}"
    echo "  1. Start a chat with your bot in Telegram"
    echo "  2. Send any message to the bot"
    echo "  3. We'll fetch your chat ID automatically..."
    echo
    read -p "Press Enter after you've messaged your bot..."

    # Fetch chat ID from recent updates
    local updates
    updates=$(curl -s --max-time 10 \
        "${TELEGRAM_API_URL}/bot${bot_token}/getUpdates" 2>/dev/null)

    local chat_id
    chat_id=$(echo "$updates" | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null)

    if [[ -z "$chat_id" ]]; then
        echo -e "${YELLOW}Could not auto-detect chat ID${NC}"
        echo "Visit: https://api.telegram.org/bot${bot_token}/getUpdates"
        echo "Find your chat ID in the response"
        echo
        read -p "Enter your chat ID manually: " chat_id
    else
        echo -e "${GREEN}Found chat ID: ${chat_id}${NC}"
        read -p "Is this correct? (Y/n): " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            read -p "Enter your chat ID manually: " chat_id
        fi
    fi

    if [[ -z "$chat_id" ]]; then
        echo -e "${RED}Error: Chat ID is required${NC}"
        return 1
    fi

    # Update .env file
    # Remove old Telegram settings if they exist
    if [[ -f ".env" ]]; then
        sed -i.bak '/^RALPH_TELEGRAM_BOT_TOKEN=/d' .env 2>/dev/null || true
        sed -i.bak '/^RALPH_TELEGRAM_CHAT_ID=/d' .env 2>/dev/null || true
        sed -i.bak '/^RALPH_TELEGRAM_ENABLED=/d' .env 2>/dev/null || true
        rm -f .env.bak 2>/dev/null || true
    fi

    # Add new settings
    {
        echo ""
        echo "# Telegram Integration (configured by setup)"
        echo "RALPH_TELEGRAM_BOT_TOKEN=${bot_token}"
        echo "RALPH_TELEGRAM_CHAT_ID=${chat_id}"
        echo "RALPH_TELEGRAM_ENABLED=true"
    } >> .env

    echo
    echo -e "${GREEN}Configuration saved to .env${NC}"
    echo

    # Test the connection
    export RALPH_TELEGRAM_BOT_TOKEN="$bot_token"
    export RALPH_TELEGRAM_CHAT_ID="$chat_id"
    export RALPH_TELEGRAM_ENABLED="true"

    echo -e "${BLUE}Step 3: Testing connection...${NC}"
    if test_telegram_connection; then
        echo
        echo -e "${GREEN}=== Setup Complete! ===${NC}"
        echo "Run Ralph with: ralph --monitor"
        echo "You'll receive notifications in Telegram."
        return 0
    else
        echo
        echo -e "${RED}Setup failed. Please check your credentials.${NC}"
        return 1
    fi
}

# ============================================
# LOGGING
# ============================================

# Log Telegram-related messages
log_telegram() {
    local level="$1"
    local message="$2"
    local timestamp=$(get_basic_timestamp)

    # Only log to file if logs directory exists
    if [[ -d "logs" ]]; then
        echo "[$timestamp] [TELEGRAM] [$level] $message" >> "logs/ralph.log"
    fi

    # Also print to stderr for debugging if RALPH_DEBUG is set
    if [[ "${RALPH_DEBUG:-}" == "true" ]]; then
        echo -e "[$timestamp] [TELEGRAM] [$level] $message" >&2
    fi
}

# ============================================
# POLLING & INTERACTIVE Q&A (Phase 2)
# ============================================

# User response file for injecting answers into loop context
USER_RESPONSE_FILE=".user_response"

# Get update offset for polling
get_update_offset() {
    if [[ -f "$TELEGRAM_OFFSET_FILE" ]]; then
        cat "$TELEGRAM_OFFSET_FILE"
    else
        echo "0"
    fi
}

# Save update offset
save_update_offset() {
    local offset="$1"
    echo "$offset" > "$TELEGRAM_OFFSET_FILE"
}

# Get updates from Telegram (poll for new messages)
# Usage: get_telegram_updates [timeout_seconds]
get_telegram_updates() {
    local timeout="${1:-30}"
    local offset=$(get_update_offset)

    if ! telegram_enabled; then
        return 1
    fi

    local response
    response=$(curl -s --max-time $((timeout + 5)) \
        "${TELEGRAM_API_URL}/bot${RALPH_TELEGRAM_BOT_TOKEN}/getUpdates" \
        -d "offset=$((offset + 1))" \
        -d "timeout=${timeout}" \
        -d "allowed_updates=[\"message\"]" \
        2>/dev/null)

    if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
        echo "$response"
        return 0
    else
        log_telegram "ERROR" "Failed to get updates: $response"
        return 1
    fi
}

# Parse a single message from updates response
# Usage: parse_telegram_message <updates_json>
# Returns: message text if from correct chat, empty otherwise
parse_telegram_message() {
    local updates_json="$1"

    # Get the first message
    local message_json=$(echo "$updates_json" | jq -r '.result[0] // empty' 2>/dev/null)

    if [[ -z "$message_json" ]]; then
        return 1
    fi

    # Extract fields
    local update_id=$(echo "$message_json" | jq -r '.update_id' 2>/dev/null)
    local chat_id=$(echo "$message_json" | jq -r '.message.chat.id' 2>/dev/null)
    local text=$(echo "$message_json" | jq -r '.message.text // empty' 2>/dev/null)

    # Update offset to acknowledge this message
    if [[ -n "$update_id" ]]; then
        save_update_offset "$update_id"
    fi

    # Validate sender
    if [[ "$chat_id" != "$RALPH_TELEGRAM_CHAT_ID" ]]; then
        log_telegram "WARNING" "Ignoring message from unauthorized chat: $chat_id"
        return 1
    fi

    # Return the message text
    if [[ -n "$text" ]]; then
        echo "$text"
        return 0
    fi

    return 1
}

# Wait for a reply from the user via Telegram
# Usage: wait_for_telegram_reply [timeout_minutes]
# Returns: user's reply text, or empty string on timeout/error
wait_for_telegram_reply() {
    local timeout_minutes="${1:-${RALPH_QUESTION_TIMEOUT:-60}}"
    local timeout_seconds=$((timeout_minutes * 60))
    local poll_interval=30  # Long polling interval
    local elapsed=0

    if ! telegram_enabled; then
        log_telegram "WARNING" "Telegram not configured, cannot wait for reply"
        return 1
    fi

    log_telegram "INFO" "Waiting for Telegram reply (timeout: ${timeout_minutes} minutes)"

    # Clear any pending updates first
    get_telegram_updates 1 > /dev/null 2>&1

    while [[ $elapsed -lt $timeout_seconds ]]; do
        # Poll for new messages
        local updates
        updates=$(get_telegram_updates $poll_interval)

        if [[ $? -eq 0 ]]; then
            local message
            message=$(parse_telegram_message "$updates")

            if [[ -n "$message" ]]; then
                # Check for skip command
                if [[ "$message" == "/skip" ]]; then
                    log_telegram "INFO" "User chose to skip question"
                    send_telegram_message "Skipping question. Ralph will decide." 2>/dev/null
                    echo ""
                    return 0
                fi

                log_telegram "INFO" "Received reply: ${message:0:50}..."
                echo "$message"
                return 0
            fi
        fi

        elapsed=$((elapsed + poll_interval))

        # Show progress every 5 minutes
        if [[ $((elapsed % 300)) -eq 0 ]]; then
            local remaining=$(( (timeout_seconds - elapsed) / 60 ))
            log_telegram "INFO" "Still waiting for reply... ${remaining} minutes remaining"
        fi
    done

    log_telegram "WARNING" "Timeout waiting for Telegram reply after ${timeout_minutes} minutes"
    send_telegram_message "Question timed out after ${timeout_minutes} minutes. Ralph will continue." 2>/dev/null
    return 1
}

# Send a question and wait for reply (convenience function)
# Usage: ask_telegram_question <question> [context] [loop_number]
# Returns: user's reply text via stdout, saves to USER_RESPONSE_FILE
ask_telegram_question() {
    local question="$1"
    local context="${2:-}"
    local loop_number="${3:-}"

    if [[ -z "$question" ]]; then
        log_telegram "ERROR" "No question provided"
        return 1
    fi

    # Send the question
    if ! send_question "$question" "$context" "$loop_number"; then
        log_telegram "ERROR" "Failed to send question to Telegram"
        return 1
    fi

    # Wait for reply
    local reply
    reply=$(wait_for_telegram_reply)
    local status=$?

    if [[ $status -eq 0 && -n "$reply" ]]; then
        # Save to file for loop context injection
        echo "$reply" > "$USER_RESPONSE_FILE"
        log_telegram "INFO" "User response saved to $USER_RESPONSE_FILE"

        # Send confirmation
        send_telegram_message "Got it! Continuing with your answer." 2>/dev/null

        echo "$reply"
        return 0
    elif [[ $status -eq 0 ]]; then
        # User skipped
        rm -f "$USER_RESPONSE_FILE"
        return 0
    else
        # Timeout or error
        rm -f "$USER_RESPONSE_FILE"
        return 1
    fi
}

# Check if there's a pending user response
has_pending_response() {
    [[ -f "$USER_RESPONSE_FILE" ]]
}

# Get and clear the pending user response
get_pending_response() {
    if [[ -f "$USER_RESPONSE_FILE" ]]; then
        cat "$USER_RESPONSE_FILE"
        rm -f "$USER_RESPONSE_FILE"
    fi
}

# Clear any pending response without reading
clear_pending_response() {
    rm -f "$USER_RESPONSE_FILE"
}

# ============================================
# TELEGRAM COMMANDS (Phase 3)
# ============================================

# State files for command control
TELEGRAM_PAUSE_FILE=".telegram_paused"
TELEGRAM_STOP_FILE=".telegram_stop"

# Check if a message is a command
is_command() {
    local message="$1"
    [[ "$message" == /* ]]
}

# Handle incoming Telegram commands
# Usage: handle_telegram_command <message>
# Returns: 0 if command was handled, 1 if not a command
handle_telegram_command() {
    local message="$1"

    if ! is_command "$message"; then
        return 1
    fi

    # Extract command (first word, lowercase)
    local command=$(echo "$message" | awk '{print tolower($1)}')
    local args=$(echo "$message" | cut -d' ' -f2- 2>/dev/null)

    log_telegram "INFO" "Received command: $command"

    case "$command" in
        /help)
            cmd_help
            ;;
        /status)
            cmd_status
            ;;
        /pause)
            cmd_pause
            ;;
        /resume)
            cmd_resume
            ;;
        /reset)
            cmd_reset
            ;;
        /stop)
            cmd_stop
            ;;
        /logs)
            cmd_logs "$args"
            ;;
        /skip)
            # Handled in wait_for_telegram_reply, just acknowledge here
            log_telegram "INFO" "Skip command acknowledged"
            ;;
        *)
            send_telegram_message "Unknown command: $command

Type /help for available commands."
            ;;
    esac

    return 0
}

# /help - Show available commands
cmd_help() {
    local help_text="*Ralph Commands*

*/status* - Show current Ralph status
*/pause* - Pause after current loop
*/resume* - Resume paused loop
*/reset* - Reset circuit breaker
*/stop* - Stop Ralph gracefully
*/logs* - Show recent log entries
*/logs N* - Show last N log entries
*/skip* - Skip current question
*/help* - Show this help"

    send_telegram_message "$help_text"
}

# /status - Show current status
cmd_status() {
    local status_text="*Ralph Status*
"

    # Get loop count from status.json
    if [[ -f "status.json" ]]; then
        local loop=$(jq -r '.loop // 0' status.json 2>/dev/null || echo "?")
        local calls=$(jq -r '.calls_made // 0' status.json 2>/dev/null || echo "?")
        local state=$(jq -r '.state // "unknown"' status.json 2>/dev/null || echo "unknown")
        status_text+="Loop: #${loop}
Calls used: ${calls}
State: ${state}
"
    else
        status_text+="No status file found
"
    fi

    # Circuit breaker state
    if [[ -f ".circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' .circuit_breaker_state 2>/dev/null || echo "UNKNOWN")
        local cb_reason=$(jq -r '.reason // ""' .circuit_breaker_state 2>/dev/null || echo "")
        status_text+="Circuit: ${cb_state}"
        if [[ -n "$cb_reason" && "$cb_reason" != "null" ]]; then
            status_text+=" (${cb_reason})"
        fi
        status_text+="
"
    fi

    # Pause state
    if [[ -f "$TELEGRAM_PAUSE_FILE" ]]; then
        status_text+="*PAUSED* - waiting to pause after current loop
"
    fi

    # Stop requested
    if [[ -f "$TELEGRAM_STOP_FILE" ]]; then
        status_text+="*STOP REQUESTED* - will stop after current loop
"
    fi

    # Session info
    if [[ -f ".claude_session_id" ]]; then
        local session_id=$(head -1 .claude_session_id 2>/dev/null | cut -c1-8)
        status_text+="Session: ${session_id}...
"
    fi

    status_text+="Time: $(get_basic_timestamp)"

    send_telegram_message "$status_text"
}

# /pause - Pause Ralph after current loop
cmd_pause() {
    if [[ -f "$TELEGRAM_PAUSE_FILE" ]]; then
        send_telegram_message "Ralph is already paused."
        return
    fi

    touch "$TELEGRAM_PAUSE_FILE"
    log_telegram "INFO" "Pause requested via Telegram"

    send_telegram_message "*Pause requested*

Ralph will pause after the current loop completes.

Use /resume to continue."
}

# /resume - Resume paused Ralph
cmd_resume() {
    if [[ ! -f "$TELEGRAM_PAUSE_FILE" ]]; then
        send_telegram_message "Ralph is not paused."
        return
    fi

    rm -f "$TELEGRAM_PAUSE_FILE"
    log_telegram "INFO" "Resume requested via Telegram"

    send_telegram_message "*Resumed*

Ralph will continue with the next loop."
}

# /reset - Reset circuit breaker
cmd_reset() {
    if [[ ! -f ".circuit_breaker_state" ]]; then
        send_telegram_message "No circuit breaker state found."
        return
    fi

    local current_state=$(jq -r '.state // "UNKNOWN"' .circuit_breaker_state 2>/dev/null)

    if [[ "$current_state" == "CLOSED" ]]; then
        send_telegram_message "Circuit breaker is already CLOSED (normal)."
        return
    fi

    # Reset circuit breaker to CLOSED
    local timestamp=$(get_iso_timestamp)
    cat > ".circuit_breaker_state" << EOF
{
    "state": "CLOSED",
    "last_change": "$timestamp",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": "Reset via Telegram command"
}
EOF

    log_telegram "INFO" "Circuit breaker reset via Telegram"

    send_telegram_message "*Circuit Breaker Reset*

State changed from ${current_state} to CLOSED.

Ralph can now continue executing."
}

# /stop - Stop Ralph gracefully
cmd_stop() {
    if [[ -f "$TELEGRAM_STOP_FILE" ]]; then
        send_telegram_message "Stop already requested."
        return
    fi

    touch "$TELEGRAM_STOP_FILE"
    log_telegram "INFO" "Stop requested via Telegram"

    send_telegram_message "*Stop requested*

Ralph will stop gracefully after the current loop.

This cannot be undone remotely - you'll need to restart Ralph manually."
}

# /logs - Show recent log entries
cmd_logs() {
    local num_lines="${1:-10}"

    # Validate number
    if ! [[ "$num_lines" =~ ^[0-9]+$ ]]; then
        num_lines=10
    fi

    # Cap at 20 lines to avoid message too long
    if [[ "$num_lines" -gt 20 ]]; then
        num_lines=20
    fi

    if [[ ! -f "logs/ralph.log" ]]; then
        send_telegram_message "No log file found."
        return
    fi

    local logs=$(tail -n "$num_lines" "logs/ralph.log" 2>/dev/null | head -c 3000)

    if [[ -z "$logs" ]]; then
        send_telegram_message "Log file is empty."
        return
    fi

    # Format for Telegram (use monospace)
    send_telegram_plain "Recent logs (last $num_lines):

$logs"
}

# Check if Ralph should pause (called from main loop)
should_pause() {
    [[ -f "$TELEGRAM_PAUSE_FILE" ]]
}

# Check if Ralph should stop (called from main loop)
should_stop() {
    [[ -f "$TELEGRAM_STOP_FILE" ]]
}

# Clear stop flag (called after stopping)
clear_stop_flag() {
    rm -f "$TELEGRAM_STOP_FILE"
}

# Clear pause flag (called when resuming)
clear_pause_flag() {
    rm -f "$TELEGRAM_PAUSE_FILE"
}

# Check for and handle any pending commands
# Usage: check_telegram_commands
# Call this periodically in the main loop
check_telegram_commands() {
    if ! telegram_enabled; then
        return 1
    fi

    # Quick poll for new messages (1 second timeout)
    local updates
    updates=$(get_telegram_updates 1 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Check if there are any messages
    local has_messages=$(echo "$updates" | grep -c '"message"' 2>/dev/null || echo "0")

    if [[ "$has_messages" -eq 0 ]]; then
        return 0
    fi

    # Parse and handle the message
    local message
    message=$(parse_telegram_message "$updates")

    if [[ -n "$message" ]]; then
        if is_command "$message"; then
            handle_telegram_command "$message"
            return 0
        fi
    fi

    return 0
}

# ============================================
# MAIN (for testing)
# ============================================

# If script is run directly, show help or run setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        setup)
            setup_telegram
            ;;
        test)
            load_env
            init_telegram
            test_telegram_connection
            ;;
        send)
            load_env
            init_telegram
            send_telegram_message "${2:-Test message from Ralph}"
            ;;
        *)
            echo "Ralph Telegram Notifier"
            echo
            echo "Usage:"
            echo "  $0 setup    - Interactive setup"
            echo "  $0 test     - Test connection"
            echo "  $0 send MSG - Send a test message"
            echo
            echo "This script is meant to be sourced by ralph_loop.sh"
            ;;
    esac
fi
