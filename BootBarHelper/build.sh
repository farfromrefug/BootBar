#!/bin/sh
# Builds the helper app and puts the APK where BootBar bundles it (BootBar/BootBarHelper.apk).
# Needs a JDK 17 or 21 (JAVA_HOME) and the Android SDK (ANDROID_HOME, or sdk.dir in local.properties).
set -eu
cd "$(dirname "$0")"
./gradlew --no-daemon -q :app:assembleRelease
cp app/build/outputs/apk/release/app-release.apk ../BootBar/BootBarHelper.apk
echo "BootBar/BootBarHelper.apk: $(wc -c < ../BootBar/BootBarHelper.apk) bytes"
