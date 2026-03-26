#!/bin/bash
# Sync chat history between local and remote server
# Usage: ./sync-chat.sh [local|remote|both]
#   local  - Copy from remote to local
#   remote - Copy from local to remote (default)
#   both   - Sync both directions (newer wins)

CHAT_FILE="CHAT-HISTORY-2026-03-25.md"
LOCAL_PATH="/Users/dominiquemb/dev/$CHAT_FILE"
REMOTE_USER="ubuntu"
REMOTE_HOST="40.160.8.176"
REMOTE_PATH="~/$CHAT_FILE"

case "${1:-remote}" in
    remote)
        echo "Syncing local → remote..."
        scp "$LOCAL_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
        echo "✓ Synced to remote server"
        ;;
    local)
        echo "Syncing remote → local..."
        scp "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH" "$LOCAL_PATH"
        echo "✓ Synced from remote server"
        ;;
    both)
        # Compare timestamps and sync newer to older
        LOCAL_TIME=$(stat -f %m "$LOCAL_PATH" 2>/dev/null || echo 0)
        REMOTE_TIME=$(ssh "$REMOTE_USER@$REMOTE_HOST" "stat -c %Y $REMOTE_PATH 2>/dev/null" || echo 0)
        
        if [ "$LOCAL_TIME" -gt "$REMOTE_TIME" ]; then
            echo "Local is newer, syncing to remote..."
            scp "$LOCAL_PATH" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
            echo "✓ Synced local → remote"
        elif [ "$REMOTE_TIME" -gt "$LOCAL_TIME" ]; then
            echo "Remote is newer, syncing to local..."
            scp "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH" "$LOCAL_PATH"
            echo "✓ Synced remote → local"
        else
            echo "✓ Files are in sync"
        fi
        ;;
    *)
        echo "Usage: $0 [local|remote|both]"
        exit 1
        ;;
esac
