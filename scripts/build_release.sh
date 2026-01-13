#!/bin/bash
# Build release APK with updated build info
# Usage: ./scripts/build_release.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Update build info with current timestamp
echo "Updating build info..."
"$SCRIPT_DIR/update_build_info.sh"

# Build release APK
echo "Building release APK..."
flutter build apk --release

# Show result
if [ $? -eq 0 ]; then
    APK_PATH="$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$APK_PATH" ]; then
        SIZE=$(ls -lh "$APK_PATH" | awk '{print $5}')
        echo ""
        echo "Build successful!"
        echo "APK: $APK_PATH"
        echo "Size: $SIZE"
    fi
else
    echo "Build failed!"
    exit 1
fi
