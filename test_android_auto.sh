#!/bin/bash

# Android Auto DHU Testing Script for CarSOC
# This script helps automate the setup and testing of Android Auto integration

set -e  # Exit on error

echo "========================================="
echo "CarSOC Android Auto DHU Testing"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step 1: Check ADB
echo -e "${YELLOW}Step 1: Checking ADB connection...${NC}"
if ! command -v adb &> /dev/null; then
    echo -e "${RED}ERROR: ADB not found. Please install Android SDK Platform Tools.${NC}"
    exit 1
fi

DEVICES=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICES" -eq 0 ]; then
    echo -e "${RED}ERROR: No Android devices connected.${NC}"
    echo "Please connect a device or start an emulator."
    exit 1
fi

echo -e "${GREEN}✓ ADB connected to $DEVICES device(s)${NC}"
adb devices
echo ""

# Step 2: Check if app is installed
echo -e "${YELLOW}Step 2: Checking if CarSOC app is installed...${NC}"
if adb shell pm list packages | grep -q "com.example.carsoc"; then
    echo -e "${GREEN}✓ CarSOC app is installed${NC}"
else
    echo -e "${RED}⚠ CarSOC app not found. Installing...${NC}"
    flutter run -d $(adb devices | grep -v "List" | grep "device$" | head -1 | awk '{print $1}') &
    APP_PID=$!
    echo "Started app installation (PID: $APP_PID)"
    echo "Waiting for app to start..."
    sleep 10
fi
echo ""

# Step 3: Check DHU
echo -e "${YELLOW}Step 3: Checking Desktop Head Unit...${NC}"
DHU_PATH="$HOME/android-auto-dhu/desktop-head-unit"

if [ ! -f "$DHU_PATH" ]; then
    echo -e "${RED}ERROR: Desktop Head Unit not found at $DHU_PATH${NC}"
    echo ""
    echo "Please download DHU from:"
    echo "https://github.com/google/android-auto-desktop-head-unit/releases"
    echo ""
    echo "Extract to: $HOME/android-auto-dhu/"
    echo ""
    read -p "Enter custom DHU path (or press Enter to exit): " CUSTOM_PATH
    if [ -z "$CUSTOM_PATH" ]; then
        exit 1
    fi
    DHU_PATH="$CUSTOM_PATH"
fi

if [ ! -x "$DHU_PATH" ]; then
    echo -e "${YELLOW}Making DHU executable...${NC}"
    chmod +x "$DHU_PATH"
fi

echo -e "${GREEN}✓ DHU found at: $DHU_PATH${NC}"
echo ""

# Step 4: Get device ID
echo -e "${YELLOW}Step 4: Selecting device...${NC}"
DEVICE_ID=$(adb devices | grep -v "List" | grep "device$" | head -1 | awk '{print $1}')
echo -e "${GREEN}✓ Using device: $DEVICE_ID${NC}"
echo ""

# Step 5: Start DHU
echo -e "${YELLOW}Step 5: Starting Desktop Head Unit...${NC}"
echo ""
echo "DHU Configuration:"
echo "  - Device: $DEVICE_ID"
echo "  - Resolution: 1920x1080"
echo "  - Touch: enabled"
echo ""
echo "Once DHU starts:"
echo "  1. Look for 'CarSOC - Battery Monitor' in the app list"
echo "  2. Tap to open the app"
echo "  3. You should see a grid with 6 cards showing vehicle data"
echo "  4. Use 'Refresh' button to update data"
echo "  5. Use 'Details' button to see detailed list view"
echo ""
echo -e "${GREEN}Starting DHU now...${NC}"
echo ""

# Run DHU with error handling
"$DHU_PATH" --adb "$DEVICE_ID" --resolution 1920x1080 --enable-touch

echo ""
echo -e "${GREEN}DHU session ended.${NC}"
