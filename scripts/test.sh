#!/bin/bash
# Run the BootKit test suite. With only the Command Line Tools installed (no Xcode),
# swift-testing lives in a non default location, so we pass its path explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$FW/Testing.framework" ] && ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
  exec swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
exec swift test "$@"
