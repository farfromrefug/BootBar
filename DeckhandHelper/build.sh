#!/bin/sh
# Builds the helper app and puts the APK where Deckhand bundles it (Deckhand/DeckhandHelper.apk).
# Needs a JDK 17 or 21 (JAVA_HOME) and the Android SDK (ANDROID_HOME, or sdk.dir in local.properties).
set -eu
cd "$(dirname "$0")"
./gradlew --no-daemon -q :app:assembleRelease
cp app/build/outputs/apk/release/app-release.apk ../Deckhand/DeckhandHelper.apk
echo "Deckhand/DeckhandHelper.apk: $(wc -c < ../Deckhand/DeckhandHelper.apk) bytes"
