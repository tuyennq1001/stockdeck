#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

REQUESTED_NAME="${1:-}"

if [ -n "$REQUESTED_NAME" ]; then
    DEVICE_ID=$(xcrun simctl list devices available | grep "$REQUESTED_NAME" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/' || true)
else
    DEVICE_ID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/' || true)
fi

if [ -z "$DEVICE_ID" ]; then
    echo "No matching iPhone simulator found. Available devices:"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
    exit 1
fi

DEVICE_NAME=$(xcrun simctl list devices available | grep "$DEVICE_ID" | head -1 | sed -E 's/^[[:space:]]*([^(]+).*/\1/' | xargs)

echo "Booting simulator: $DEVICE_NAME ($DEVICE_ID)..."
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator

echo "Building StockDeck for iOS Simulator ($DEVICE_NAME)..."
swift build --sdk $(xcrun --sdk iphonesimulator --show-sdk-path) --target StockDeck 2>&1 | tail -20 || true

echo "Simulator launched!"
