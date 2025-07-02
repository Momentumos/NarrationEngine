#!/bin/bash
#
# Orpheus Worker Daemon Management Script
# Provides easy daemon management with multiple options
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Emojis (fallback to text if not supported)
if [[ "$OSTYPE" == "darwin"* ]]; then
    ROCKET="🚀"
    CHECK="✅"
    WARNING="⚠️"
    ERROR="❌"
    STOP="🛑"
    INFO="ℹ️"
    GEAR="🔧"
    LOG="📋"
else
    ROCKET="[START]"
    CHECK="[OK]"
    WARNING="[WARN]"
    ERROR="[ERROR]"
    STOP="[STOP]"
    INFO="[INFO]"
    GEAR="[CONFIG]"
    LOG="[LOG]"
fi

# Default configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_CMD="python3"
DAEMON_SCRIPT="$SCRIPT_DIR/daemon_worker.py"
PID_FILE="$SCRIPT_DIR/worker_daemon.pid"
LOG_FILE="$SCRIPT_DIR/worker_daemon.log"
ENV_FILE="$SCRIPT_DIR/.env"

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success")
            echo -e "${GREEN}${CHECK} ${message}${NC}"
            ;;
        "error")
            echo -e "${RED}${ERROR} ${message}${NC}"
            ;;
        "warning")
            echo -e "${YELLOW}${WARNING} ${message}${NC}"
            ;;
        "info")
            echo -e "${BLUE}${INFO} ${message}${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Function to check if daemon script exists
check_daemon_script() {
    if [[ ! -f "$DAEMON_SCRIPT" ]]; then
        print_status "error" "Daemon script not found: $DAEMON_SCRIPT"
        return 1
    fi
    return 0
}

# Function to check Python and dependencies
check_dependencies() {
    # Check Python
    if ! command -v "$PYTHON_CMD" &> /dev/null; then
        print_status "error" "Python3 not found. Please install Python 3.8 or higher."
        return 1
    fi
    
    # Check Python version
    local python_version=$($PYTHON_CMD -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    local major_version=$(echo $python_version | cut -d. -f1)
    local minor_version=$(echo $python_version | cut -d. -f2)
    
    if [[ $major_version -lt 3 ]] || [[ $major_version -eq 3 && $minor_version -lt 8 ]]; then
        print_status "error" "Python 3.8 or higher is required. Current version: $python_version"
        return 1
    fi
    
    # Check .env file
    if [[ ! -f "$ENV_FILE" ]]; then
        print_status "warning" ".env file not found: $ENV_FILE"
        print_status "info" "Please create .env file with your configuration"
        return 1
    fi
    
    return 0
}

# Function to start daemon
start_daemon() {
    print_status "info" "${ROCKET} Starting Orpheus Worker Daemon..."
    
    if ! check_daemon_script || ! check_dependencies; then
        return 1
    fi
    
    # Check if already running
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_status "warning" "Daemon already running with PID $pid"
            return 1
        else
            print_status "info" "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Start daemon
    if $PYTHON_CMD "$DAEMON_SCRIPT" start --pidfile="$PID_FILE" --logfile="$LOG_FILE" --workdir="$SCRIPT_DIR"; then
        sleep 2
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE" 2>/dev/null)
            print_status "success" "Daemon started successfully with PID $pid"
            print_status "info" "Log file: $LOG_FILE"
            print_status "info" "PID file: $PID_FILE"
        else
            print_status "error" "Daemon failed to start (no PID file created)"
            return 1
        fi
    else
        print_status "error" "Failed to start daemon"
        return 1
    fi
}

# Function to stop daemon
stop_daemon() {
    print_status "info" "${STOP} Stopping Orpheus Worker Daemon..."
    
    if ! check_daemon_script; then
        return 1
    fi
    
    if $PYTHON_CMD "$DAEMON_SCRIPT" stop --pidfile="$PID_FILE"; then
        print_status "success" "Daemon stopped successfully"
    else
        print_status "error" "Failed to stop daemon"
        return 1
    fi
}

# Function to restart daemon
restart_daemon() {
    print_status "info" "${GEAR} Restarting Orpheus Worker Daemon..."
    
    if ! check_daemon_script; then
        return 1
    fi
    
    if $PYTHON_CMD "$DAEMON_SCRIPT" restart --pidfile="$PID_FILE" --logfile="$LOG_FILE" --workdir="$SCRIPT_DIR"; then
        sleep 2
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE" 2>/dev/null)
            print_status "success" "Daemon restarted successfully with PID $pid"
        else
            print_status "error" "Daemon failed to restart (no PID file created)"
            return 1
        fi
    else
        print_status "error" "Failed to restart daemon"
        return 1
    fi
}

# Function to check daemon status
status_daemon() {
    if ! check_daemon_script; then
        return 1
    fi
    
    $PYTHON_CMD "$DAEMON_SCRIPT" status --pidfile="$PID_FILE"
}

# Function to show logs
show_logs() {
    local lines=${1:-50}
    
    if [[ ! -f "$LOG_FILE" ]]; then
        print_status "warning" "Log file not found: $LOG_FILE"
        return 1
    fi
    
    print_status "info" "${LOG} Showing last $lines lines from $LOG_FILE"
    echo "----------------------------------------"
    tail -n "$lines" "$LOG_FILE"
}

# Function to follow logs
follow_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_status "warning" "Log file not found: $LOG_FILE"
        print_status "info" "Waiting for log file to be created..."
        
        # Wait for log file to be created (up to 30 seconds)
        for i in {1..30}; do
            if [[ -f "$LOG_FILE" ]]; then
                break
            fi
            sleep 1
        done
        
        if [[ ! -f "$LOG_FILE" ]]; then
            print_status "error" "Log file was not created"
            return 1
        fi
    fi
    
    print_status "info" "${LOG} Following logs from $LOG_FILE (Press Ctrl+C to stop)"
    echo "----------------------------------------"
    tail -f "$LOG_FILE"
}

# Function to run in foreground (non-daemon mode)
run_foreground() {
    print_status "info" "${ROCKET} Running Orpheus Worker in foreground mode..."
    
    if ! check_dependencies; then
        return 1
    fi
    
    # Check if daemon is already running
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_status "error" "Daemon is already running with PID $pid. Stop it first or use 'status' to check."
            return 1
        fi
    fi
    
    # Run worker system directly
    cd "$SCRIPT_DIR"
    exec $PYTHON_CMD run_workers.py
}

# Function to show help
show_help() {
    echo "Orpheus Worker Daemon Management Script"
    echo "======================================"
    echo
    echo "Usage: $0 {start|stop|restart|status|logs|follow|run|help}"
    echo
    echo "Commands:"
    echo "  start     - Start the daemon in background"
    echo "  stop      - Stop the daemon"
    echo "  restart   - Restart the daemon"
    echo "  status    - Show daemon status"
    echo "  logs [N]  - Show last N lines of logs (default: 50)"
    echo "  follow    - Follow logs in real-time"
    echo "  run       - Run in foreground (non-daemon mode)"
    echo "  help      - Show this help message"
    echo
    echo "Files:"
    echo "  Daemon script: $DAEMON_SCRIPT"
    echo "  PID file:      $PID_FILE"
    echo "  Log file:      $LOG_FILE"
    echo "  Config file:   $ENV_FILE"
    echo
    echo "Examples:"
    echo "  $0 start          # Start daemon"
    echo "  $0 status         # Check if running"
    echo "  $0 logs 100       # Show last 100 log lines"
    echo "  $0 follow         # Follow logs in real-time"
    echo "  $0 run            # Run in foreground for debugging"
}

# Main function
main() {
    local command=${1:-help}
    
    case $command in
        "start")
            start_daemon
            ;;
        "stop")
            stop_daemon
            ;;
        "restart")
            restart_daemon
            ;;
        "status")
            status_daemon
            ;;
        "logs")
            show_logs "$2"
            ;;
        "follow")
            follow_logs
            ;;
        "run")
            run_foreground
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_status "error" "Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
