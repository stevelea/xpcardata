#!/bin/bash

# CarSOC APK Build Script
# Builds release APK for real device testing

set -e  # Exit on error

echo "========================================="
echo "CarSOC APK Builder"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if Flutter is available
if ! command -v flutter &> /dev/null; then
    echo -e "${RED}ERROR: Flutter not found in PATH${NC}"
    echo "Please add Flutter to your PATH:"
    echo "export PATH=\"\$PATH:/Users/stevelea/flutter/bin\""
    exit 1
fi

echo -e "${BLUE}Flutter version:${NC}"
flutter --version
echo ""

# Ask user what kind of build
echo -e "${YELLOW}Select build type:${NC}"
echo "1) Debug APK (faster build, larger size, ~60 MB)"
echo "2) Release APK - Fat (all architectures, ~50 MB) [RECOMMENDED]"
echo "3) Release APK - Split per ABI (smaller, ~20 MB each)"
echo ""
read -p "Enter choice [1-3] (default: 2): " BUILD_CHOICE
BUILD_CHOICE=${BUILD_CHOICE:-2}

# Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
flutter clean
echo ""

# Get dependencies
echo -e "${YELLOW}Getting dependencies...${NC}"
flutter pub get
echo ""

# Build APK based on choice
case $BUILD_CHOICE in
    1)
        echo -e "${GREEN}Building DEBUG APK...${NC}"
        flutter build apk --debug
        APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
        ;;
    2)
        echo -e "${GREEN}Building RELEASE APK (fat)...${NC}"
        flutter build apk --release
        APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
        ;;
    3)
        echo -e "${GREEN}Building RELEASE APK (split per ABI)...${NC}"
        flutter build apk --release --split-per-abi
        APK_PATH="build/app/outputs/flutter-apk/"
        ;;
    *)
        echo -e "${RED}Invalid choice. Defaulting to release APK.${NC}"
        flutter build apk --release
        APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
        ;;
esac

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""

# Show APK location and size
if [ "$BUILD_CHOICE" == "3" ]; then
    echo -e "${BLUE}APKs created:${NC}"
    ls -lh build/app/outputs/flutter-apk/*.apk | awk '{print $9, "(" $5 ")"}'
    echo ""
    echo -e "${YELLOW}Recommendation: Use app-arm64-v8a-release.apk for most modern devices${NC}"
else
    echo -e "${BLUE}APK location:${NC} $APK_PATH"
    APK_SIZE=$(ls -lh "$APK_PATH" | awk '{print $5}')
    echo -e "${BLUE}APK size:${NC} $APK_SIZE"
fi

echo ""

# Check if device is connected
DEVICES=$(adb devices 2>/dev/null | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICES" -gt 0 ]; then
    echo -e "${GREEN}Android device detected!${NC}"
    adb devices
    echo ""
    read -p "Install APK on connected device now? [y/N]: " INSTALL_NOW

    if [[ "$INSTALL_NOW" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${YELLOW}Installing APK...${NC}"

        if [ "$BUILD_CHOICE" == "3" ]; then
            echo "Which APK do you want to install?"
            echo "1) arm64-v8a (most modern 64-bit devices)"
            echo "2) armeabi-v7a (older 32-bit devices)"
            echo "3) x86_64 (Intel-based devices)"
            read -p "Enter choice [1-3] (default: 1): " APK_CHOICE
            APK_CHOICE=${APK_CHOICE:-1}

            case $APK_CHOICE in
                1) INSTALL_APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" ;;
                2) INSTALL_APK="build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk" ;;
                3) INSTALL_APK="build/app/outputs/flutter-apk/app-x86_64-release.apk" ;;
                *) INSTALL_APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" ;;
            esac
        else
            INSTALL_APK="$APK_PATH"
        fi

        # Try to uninstall old version first
        adb uninstall com.example.carsoc 2>/dev/null || true

        # Install new version
        if adb install "$INSTALL_APK"; then
            echo ""
            echo -e "${GREEN}✓ Installation successful!${NC}"
            echo ""
            echo "You can now:"
            echo "1. Open CarSOC app on your device"
            echo "2. Grant any requested permissions"
            echo "3. Test all features (settings will persist!)"
            echo "4. Connect to car for Android Auto testing"
        else
            echo ""
            echo -e "${RED}✗ Installation failed${NC}"
            echo "Try installing manually:"
            echo "1. Copy APK to device: adb push $INSTALL_APK /sdcard/Download/CarSOC.apk"
            echo "2. On device: Files → Downloads → CarSOC.apk → Install"
        fi
    fi
else
    echo -e "${YELLOW}No Android device detected via ADB${NC}"
    echo ""
    echo "To install APK:"
    echo ""
    echo "Option 1 - USB Installation:"
    echo "  1. Enable USB debugging on your device"
    echo "  2. Connect device via USB"
    echo "  3. Run: adb install $APK_PATH"
    echo ""
    echo "Option 2 - Manual Installation:"
    echo "  1. Copy APK to your device"
    if [ "$BUILD_CHOICE" == "3" ]; then
        echo "  2. File location: build/app/outputs/flutter-apk/"
    else
        echo "  2. File location: $APK_PATH"
    fi
    echo "  3. On device: Open Files app → Navigate to APK → Install"
    echo ""
fi

echo ""
echo -e "${BLUE}For more details, see BUILD_APK.md${NC}"
echo ""
