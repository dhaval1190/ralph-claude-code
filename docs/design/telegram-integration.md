# Telegram Integration Design Document

## Overview

This document describes the design for integrating Ralph with Telegram, enabling:
- Remote notifications for questions, errors, and status updates
- Interactive Q&A when Claude needs human input
- Mobile monitoring of autonomous development loops

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Ralph Loop                                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │ ralph_loop.sh│───►│ response_    │───►│ telegram_notifier.sh │  │
│  │              │    │ analyzer.sh  │    │                      │  │
│  └──────────────┘    └──────────────┘    └──────────┬───────────┘  │
│         ▲                                           │              │
│         │                                           ▼              │
│  ┌──────┴───────┐                         ┌─────────────────┐      │
│  │.user_response│◄────────────────────────│  Telegram API   │      │
│  └──────────────┘                         └────────┬────────┘      │
└─────────────────────────────────────────────────────┼───────────────┘
                                                      │
                                                      ▼
                                              ┌───────────────┐
                                              │  Your Phone   │
                                              │  (Telegram)   │
                                              └───────────────┘
```

## Components

### 1. New Library: `lib/telegram_notifier.sh`

**Purpose:** Handle all Telegram API communication

**Functions:**
```bash
# Configuration
init_telegram()              # Validate token and chat_id
test_telegram_connection()   # Send test message

# Sending
send_telegram_message()      # Send plain text
send_telegram_question()     # Send question with reply keyboard
send_telegram_status()       # Send formatted status update
send_telegram_error()        # Send error alert with details

# Receiving
get_telegram_updates()       # Poll for new messages
wait_for_telegram_reply()    # Block until user responds (with timeout)
parse_telegram_response()    # Extract text from API response

# State
save_update_offset()         # Track last processed message
get_update_offset()          # Retrieve offset for polling
```

### 2. Configuration: `.env` File

Copy `.env.example` to `.env` and configure:

```bash
# Required - from @BotFather
RALPH_TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
RALPH_TELEGRAM_CHAT_ID=987654321
RALPH_TELEGRAM_ENABLED=true

# Notification settings
RALPH_NOTIFY_QUESTION=true
RALPH_NOTIFY_LOOP_COMPLETE=true
RALPH_NOTIFY_ERROR=true
RALPH_NOTIFY_CIRCUIT_BREAKER=true
RALPH_NOTIFY_RATE_LIMIT=true

# Question handling
RALPH_QUESTION_TIMEOUT=60
RALPH_AUTO_SKIP_QUESTIONS=false

# Quiet hours (optional)
RALPH_QUIET_HOURS_ENABLED=false
RALPH_QUIET_HOURS_START=23:00
RALPH_QUIET_HOURS_END=07:00
```

**Loading in bash:**
```bash
# Source .env file
load_env() {
    if [[ -f ".env" ]]; then
        set -a  # Export all variables
        source .env
        set +a
    fi
}
```

### 3. New RALPH_STATUS Field: `QUESTION`

Update `templates/PROMPT.md` to support:

```
---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
QUESTION: Which database should I use - PostgreSQL or SQLite?
QUESTION_CONTEXT: Need to implement user storage. PostgreSQL better for production, SQLite simpler for development.
RECOMMENDATION: Waiting for user decision on database choice
---END_RALPH_STATUS---
```

**New Fields:**
- `QUESTION` - The question Claude wants to ask (optional)
- `QUESTION_CONTEXT` - Additional context to help user decide (optional)

## Message Formats

### Question Message (to user)

```
🤖 *Ralph needs your input*

*Question:*
Which database should I use - PostgreSQL or SQLite?

*Context:*
Need to implement user storage. PostgreSQL better for production, SQLite simpler for development.

*Loop:* #15 | *Project:* my-app

Reply with your answer or type /skip to let Ralph decide.
```

### Status Update Messages

**Loop Complete:**
```
✅ *Loop #15 Complete*

Tasks completed: 3
Files modified: 7
Tests: PASSING

Next: Continue with API authentication
```

**Error:**
```
❌ *Ralph Error*

Loop #15 failed with error:
`npm test exited with code 1`

Circuit breaker: HALF_OPEN (2/3 failures)
```

**Circuit Breaker Open:**
```
🛑 *Circuit Breaker OPEN*

Ralph has stopped after 3 loops with no progress.

*Reason:* Same error repeated
*Last error:* TypeError: Cannot read property 'id' of undefined

Reply /reset to reset circuit breaker
Reply /status for full status
```

**Rate Limit:**
```
⏳ *Rate Limit Reached*

100/100 API calls used this hour.
Resuming in: 45:23

Ralph will continue automatically.
```

## Telegram Commands

Users can send commands to control Ralph:

| Command | Action |
|---------|--------|
| `/status` | Get current Ralph status |
| `/pause` | Pause the loop after current iteration |
| `/resume` | Resume paused loop |
| `/reset` | Reset circuit breaker |
| `/skip` | Skip current question, let Claude decide |
| `/stop` | Gracefully stop Ralph |
| `/logs` | Get last 10 log lines |
| `/help` | Show available commands |

## Integration Points

### 1. ralph_loop.sh Modifications

```bash
# At script start
source "$SCRIPT_DIR/lib/telegram_notifier.sh"
init_telegram_if_configured

# After response analysis (line ~850)
if [[ -n "$question" ]]; then
    send_telegram_question "$question" "$question_context" "$LOOP_NUMBER"

    # Wait for reply with timeout
    user_answer=$(wait_for_telegram_reply "$QUESTION_TIMEOUT")

    if [[ -n "$user_answer" ]]; then
        echo "$user_answer" > .user_response
        # Answer will be injected into next loop context
    fi
fi

# After loop completion (line ~900)
if telegram_enabled && notify_loop_complete; then
    send_telegram_status "$LOOP_NUMBER" "$tasks_completed" "$files_modified" "$test_status"
fi

# On error (line ~950)
if telegram_enabled && notify_error; then
    send_telegram_error "$error_message" "$LOOP_NUMBER"
fi

# Circuit breaker state change (line ~980)
if telegram_enabled && notify_circuit_breaker; then
    send_telegram_circuit_breaker "$new_state" "$reason"
fi
```

### 2. response_analyzer.sh Modifications

```bash
# Add to parse_ralph_status() function
extract_question() {
    local output="$1"

    # Extract QUESTION field if present
    local question=$(echo "$output" | grep -oP 'QUESTION:\s*\K.*' | head -1)
    local context=$(echo "$output" | grep -oP 'QUESTION_CONTEXT:\s*\K.*' | head -1)

    if [[ -n "$question" ]]; then
        echo "{\"question\": \"$question\", \"context\": \"$context\"}"
    fi
}
```

### 3. build_loop_context() Enhancement

```bash
build_loop_context() {
    local context="Loop iteration: $LOOP_NUMBER. "

    # ... existing context building ...

    # Inject user's answer if available
    if [[ -f ".user_response" ]]; then
        local user_answer=$(cat .user_response)
        context+="USER ANSWERED YOUR QUESTION: \"$user_answer\". "
        context+="Please proceed based on this answer. "
        rm -f .user_response
    fi

    echo "$context"
}
```

## Telegram Bot Setup

### Step 1: Create Bot

1. Open Telegram, search for `@BotFather`
2. Send `/newbot`
3. Choose a name: `Ralph Development Bot`
4. Choose a username: `ralph_dev_bot` (must end in `bot`)
5. Save the token: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`

### Step 2: Get Chat ID

1. Start a chat with your new bot
2. Send any message
3. Visit: `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. Find `"chat":{"id":987654321}` in the response
5. Save your chat_id: `987654321`

### Step 3: Configure Ralph

```bash
# Copy the example file
cp .env.example .env

# Edit with your credentials
nano .env  # or your preferred editor

# Set your token and chat ID
RALPH_TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
RALPH_TELEGRAM_CHAT_ID=987654321
RALPH_TELEGRAM_ENABLED=true
```

## CLI Flags

New flags for `ralph` command:

```bash
# Setup
ralph --telegram-setup          # Interactive Telegram configuration
ralph --telegram-test           # Send test message

# Runtime control
ralph --telegram                # Enable Telegram notifications
ralph --no-telegram             # Disable Telegram notifications
ralph --telegram-token TOKEN    # Override token
ralph --telegram-chat CHAT_ID   # Override chat ID

# Question handling
ralph --question-timeout 60     # Minutes to wait for answer (default: 60)
ralph --auto-skip-questions     # Never wait, let Claude decide
```

## State Files

| File | Purpose |
|------|---------|
| `.env` | Configuration (token, chat_id, all settings) |
| `.env.example` | Template showing all available options |
| `.telegram_offset` | Last processed update ID (for polling) |
| `.user_response` | User's answer to inject into next loop |
| `.telegram_paused` | Flag file when user sends /pause |

## Security Considerations

### Token Security

1. **Never commit .env** - Already in `.gitignore`:
   ```
   .env
   .telegram_offset
   .user_response
   ```

2. **Only commit the example file:**
   ```bash
   git add .env.example   # Safe - no secrets
   # .env is gitignored   # Contains secrets
   ```

3. **File permissions:**
   ```bash
   chmod 600 .env
   ```

### Chat ID Validation

Only respond to messages from configured chat_id:
```bash
validate_sender() {
    local message_chat_id="$1"
    if [[ "$message_chat_id" != "$CONFIGURED_CHAT_ID" ]]; then
        log "WARNING: Ignoring message from unauthorized chat: $message_chat_id"
        return 1
    fi
    return 0
}
```

### Rate Limiting

Prevent Telegram API abuse:
```bash
TELEGRAM_MIN_INTERVAL=1  # Minimum seconds between messages
last_telegram_send=0

rate_limit_telegram() {
    local now=$(date +%s)
    local elapsed=$((now - last_telegram_send))
    if [[ $elapsed -lt $TELEGRAM_MIN_INTERVAL ]]; then
        sleep $((TELEGRAM_MIN_INTERVAL - elapsed))
    fi
    last_telegram_send=$(date +%s)
}
```

## Error Handling

### Network Failures

```bash
send_telegram_message() {
    local message="$1"
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        response=$(curl -s --max-time 10 \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=Markdown")

        if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
            return 0
        fi

        ((retry++))
        sleep $((retry * 2))  # Exponential backoff
    done

    log "ERROR: Failed to send Telegram message after $max_retries retries"
    return 1
}
```

### Graceful Degradation

If Telegram is unavailable, Ralph continues without blocking:
```bash
send_telegram_question() {
    if ! send_telegram_message "$question"; then
        log "WARNING: Could not send question to Telegram, continuing without user input"
        return 1
    fi
    # ... wait for reply
}
```

## Testing

### Unit Tests (`tests/unit/test_telegram.bats`)

```bash
@test "send_telegram_message formats correctly" { ... }
@test "parse_telegram_response extracts text" { ... }
@test "validate_sender rejects wrong chat_id" { ... }
@test "rate limiting prevents spam" { ... }
@test "wait_for_reply times out correctly" { ... }
```

### Integration Tests

```bash
@test "telegram notification on circuit breaker open" { ... }
@test "question flow end-to-end" { ... }
@test "telegram commands work" { ... }
```

### Manual Testing

```bash
# Test connection
ralph --telegram-test

# Test with mock server (for CI)
TELEGRAM_API_URL="http://localhost:8080" ralph --telegram-test
```

## Implementation Phases

### Phase 1: Basic Notifications (MVP)
- [ ] Create `lib/telegram_notifier.sh` with send functions
- [ ] Add configuration file support
- [ ] Integrate basic status notifications
- [ ] Add `--telegram-setup` CLI flag
- [ ] Add tests

### Phase 2: Interactive Questions
- [ ] Add QUESTION field to RALPH_STATUS parsing
- [ ] Implement `wait_for_telegram_reply()`
- [ ] Inject answers into loop context
- [ ] Add timeout handling
- [ ] Update PROMPT.md template

### Phase 3: Commands & Control
- [ ] Implement command handler for `/status`, `/pause`, etc.
- [ ] Add background polling for commands (optional)
- [ ] Implement `/logs` command
- [ ] Add quiet hours support

### Phase 4: Polish
- [ ] Add message formatting (emojis, markdown)
- [ ] Implement retry logic with backoff
- [ ] Add comprehensive error handling
- [ ] Documentation and examples

## Example Session

```
You                                     Ralph Bot
 │                                           │
 │     ┌─────────────────────────────────────┤
 │     │ ✅ Loop #1 Complete                 │
 │     │ Tasks: 2 | Files: 5 | Tests: PASS   │
 │     └─────────────────────────────────────┤
 │                                           │
 │     ┌─────────────────────────────────────┤
 │     │ ✅ Loop #2 Complete                 │
 │     │ Tasks: 1 | Files: 3 | Tests: PASS   │
 │     └─────────────────────────────────────┤
 │                                           │
 │     ┌─────────────────────────────────────┤
 │     │ 🤖 Ralph needs your input           │
 │     │                                     │
 │     │ Question:                           │
 │     │ Should I use REST or GraphQL for    │
 │     │ the API?                            │
 │     │                                     │
 │     │ Context:                            │
 │     │ REST is simpler, GraphQL more       │
 │     │ flexible for complex queries.       │
 │     └─────────────────────────────────────┤
 │                                           │
 ├─────────────────────────────────────►     │
 │  "Use REST, keep it simple"               │
 │                                           │
 │     ┌─────────────────────────────────────┤
 │     │ ✅ Got it! Continuing with REST...  │
 │     └─────────────────────────────────────┤
 │                                           │
 │     ┌─────────────────────────────────────┤
 │     │ ✅ Loop #3 Complete                 │
 │     │ Tasks: 3 | Files: 8 | Tests: PASS   │
 │     │ Implemented REST API endpoints      │
 │     └─────────────────────────────────────┤
 │                                           │
```

## Dependencies

- `curl` - HTTP requests to Telegram API
- `jq` - JSON parsing (already a Ralph dependency)
- Telegram account and bot token

## References

- [Telegram Bot API Documentation](https://core.telegram.org/bots/api)
- [BotFather](https://t.me/botfather)
- [getUpdates method](https://core.telegram.org/bots/api#getupdates)
- [sendMessage method](https://core.telegram.org/bots/api#sendmessage)
