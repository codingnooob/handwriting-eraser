#!/bin/sh
set -eu

# GitHub Actions passes these as environment variables. If none are present,
# produce an ad-hoc-signed release; never silently accept partial credentials.
certificate=${MACOS_CERTIFICATE_BASE64:-}
password=${MACOS_CERTIFICATE_PASSWORD:-}
identity=${MACOS_SIGNING_IDENTITY:-}
apple_id=${APPLE_ID:-}
app_password=${APPLE_APP_SPECIFIC_PASSWORD:-}
team=${APPLE_TEAM_ID:-}
output=${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}

if [ -z "$certificate$password$identity$apple_id$app_password$team" ]; then
    printf 'identity=-\nnotarize=false\n' >> "$output"
    echo 'No Apple signing credentials configured; building an ad-hoc-signed, non-notarized DMG.'
    exit 0
fi
if [ -z "$certificate" ] || [ -z "$password" ] || [ -z "$identity" ] || \
   [ -z "$apple_id" ] || [ -z "$app_password" ] || [ -z "$team" ]; then
    echo 'Apple signing is partially configured. Set all six documented signing/notarization secrets, or remove them all.' >&2
    exit 1
fi
case "$identity" in *'
'*) echo 'Signing identity must be a single line.' >&2; exit 1 ;; esac

runner_temp=${RUNNER_TEMP:?RUNNER_TEMP is required for signing}
keychain="$runner_temp/handwriting-signing.keychain-db"
certificate_file="$runner_temp/handwriting-certificate.p12"
keychain_password=$(openssl rand -hex 24)
trap 'rm -f "$certificate_file"' EXIT HUP INT TERM
printf '%s' "$certificate" | base64 -D > "$certificate_file"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate_file" -k "$keychain" -P "$password" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
printf 'identity=%s\nnotarize=true\n' "$identity" >> "$output"
echo 'Apple Developer ID signing and notarization are configured.'
