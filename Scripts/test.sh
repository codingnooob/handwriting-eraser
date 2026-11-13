#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Some Command Line Tools installations do not automatically discover the
# Swift Testing macro plugin. Load it explicitly when it is present.
swiftc_path=$(xcrun --find swiftc)
toolchain_usr=$(dirname "$(dirname "$swiftc_path")")
plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$plugin" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
else
    exec swift test "$@"
fi
