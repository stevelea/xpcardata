#!/bin/bash
set -e
export HOME=/Volumes/UgreenEXT/CarSOC/carsoc/.home
export PUB_CACHE=/Volumes/UgreenEXT/CarSOC/carsoc/.pub_cache
export GRADLE_USER_HOME=/Volumes/UgreenEXT/CarSOC/carsoc/.gradle_home
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME=/Users/stevelea/Library/Android/sdk
export ANDROID_SDK_ROOT=/Users/stevelea/Library/Android/sdk
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
cd /Volumes/UgreenEXT/CarSOC/carsoc
./.flutter_sdk/bin/flutter build apk --release --suppress-analytics 2>&1
