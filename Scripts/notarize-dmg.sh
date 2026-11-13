#!/bin/sh
set -eu
image=${1:?Usage: Scripts/notarize-dmg.sh IMAGE}
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

xcrun notarytool submit "$image" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --timeout 20m
xcrun stapler staple "$image"
xcrun stapler validate "$image"
