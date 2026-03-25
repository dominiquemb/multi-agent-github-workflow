#!/bin/bash
# Screen recording helper for task execution
# Records the terminal session and browser activity

SCREENCAST_DIR="${SCREENCAST_DIR:-/workspace/e2e/screenshots}"
TASK_NAME="${TASK_NAME:-task}"

mkdir -p "$SCREENCAST_DIR"

# Function to start screen recording
start_recording() {
    local session_name="$1"
    echo "Starting screen recording: $session_name"
    
    # Start Xvfb if not running
    if ! pgrep -x Xvfb > /dev/null; then
        Xvfb :99 -screen 0 1920x1080x24 &
        export DISPLAY=:99
    fi
    
    # Start fluxbox window manager
    if ! pgrep -x fluxbox > /dev/null; then
        fluxbox &
        sleep 2
    fi
    
    # Start screen recording with ffmpeg
    ffmpeg -y \
        -f x11grab \
        -video_size 1920x1080 \
        -i :99 \
        -f pulse -i default \
        -c:v libx264 -preset ultrafast -crf 18 \
        -c:a aac \
        "$SCREENCAST_DIR/${TASK_NAME}-${session_name}.mp4" \
        2>/dev/null &
    
    echo $! > /tmp/recording_pid
    echo "Recording started (PID: $(cat /tmp/recording_pid))"
}

# Function to stop screen recording
stop_recording() {
    if [ -f /tmp/recording_pid ]; then
        local pid=$(cat /tmp/recording_pid)
        if kill -0 $pid 2>/dev/null; then
            kill $pid
            wait $pid 2>/dev/null
            echo "Recording stopped"
        fi
        rm /tmp/recording_pid
    fi
}

# Function to take a screenshot
take_screenshot() {
    local name="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="${SCREENCAST_DIR}/${TASK_NAME}-${name:-screenshot}-${timestamp}.png"
    
    if [ -n "$DISPLAY" ] && command -v scrot &> /dev/null; then
        scrot "$filename"
        echo "Screenshot saved: $filename"
    else
        # Fallback: use ImageMagick import
        if command -v import &> /dev/null; then
            import -window root "$filename"
            echo "Screenshot saved: $filename"
        else
            echo "Warning: No screenshot tool available"
        fi
    fi
}

# Function to capture terminal session
capture_terminal() {
    # This function logs all terminal output
    exec > >(tee -a "$SCREENCAST_DIR/${TASK_NAME}-terminal.log") 2>&1
    echo "Terminal capture started at $(date)"
}

# Function to generate summary report
generate_report() {
    local report_file="$SCREENCAST_DIR/${TASK_NAME}-summary.md"
    
    cat > "$report_file" << EOF
# Task Execution Report

**Task:** $TASK_NAME
**Date:** $(date)
**Host:** $(hostname)

## Screenshots and Recordings

EOF

    # List all screenshots
    echo "### Screenshots" >> "$report_file"
    for img in "$SCREENCAST_DIR"/${TASK_NAME}-*.png; do
        if [ -f "$img" ]; then
            echo "- ![$(basename "$img")]($(basename "$img"))" >> "$report_file"
        fi
    done
    
    echo "" >> "$report_file"
    echo "### Screen Recordings" >> "$report_file"
    for vid in "$SCREENCAST_DIR"/${TASK_NAME}-*.mp4; do
        if [ -f "$vid" ]; then
            echo "- [$(basename "$vid")]($(basename "$vid"))" >> "$report_file"
        fi
    done
    
    echo "" >> "$report_file"
    echo "## Terminal Log" >> "$report_file"
    if [ -f "$SCREENCAST_DIR/${TASK_NAME}-terminal.log" ]; then
        echo '```' >> "$report_file"
        tail -100 "$SCREENCAST_DIR/${TASK_NAME}-terminal.log" >> "$report_file"
        echo '```' >> "$report_file"
    fi
    
    echo "Report generated: $report_file"
}

# Export functions for use in other scripts
export -f start_recording stop_recording take_screenshot capture_terminal generate_report

# If called directly with arguments, execute them
if [ $# -gt 0 ]; then
    "$@"
fi
