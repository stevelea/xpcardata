#!/bin/bash
# Pre-build script to update build_info.dart with current timestamp
# Run this before flutter build, or add to your build process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_INFO_FILE="$PROJECT_DIR/lib/build_info.dart"

# Get current date/time in the format YYYY-MM-DD HH:MM
BUILD_DATETIME=$(date "+%Y-%m-%d %H:%M")

# Write the build_info.dart file
cat > "$BUILD_INFO_FILE" << EOF
/// Auto-generated build information
/// This file is regenerated during each build to capture the build timestamp
class BuildInfo {
  /// The date and time when this build was created
  /// Format: YYYY-MM-DD HH:MM
  static const String buildDateTime = '$BUILD_DATETIME';
}
EOF

echo "Updated build_info.dart with timestamp: $BUILD_DATETIME"
