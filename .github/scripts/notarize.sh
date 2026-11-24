#!/usr/bin/env bash
# Submits a .zip / .dmg / .pkg to Apple's notary service and waits for the verdict.
# Credentials come from the environment: APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM_ID.
set -euo pipefail

file="${1:?usage: notarize.sh <file>}"
: "${APPLE_ID:?}" "${APPLE_PASSWORD:?}" "${APPLE_TEAM_ID:?}"

result=$(xcrun notarytool submit "$file" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_PASSWORD" \
  --wait --timeout 30m \
  --output-format json)
echo "$result"

status=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
id=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')

if [ "$status" != "Accepted" ]; then
  echo "::error::Notarization of $(basename "$file") finished with status '$status'"
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" || true
  fi
  exit 1
fi
echo "Notarized $(basename "$file")"
