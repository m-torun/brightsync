#!/bin/zsh
# Runs the tests. With only the Command Line Tools installed (no Xcode),
# swift-testing ships with the toolchain but is not on the default search path,
# and its Foundation overlay is missing its module, so overlays are turned off.
set -e
cd "$(dirname "$0")"

FLAGS=()
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ ! -d "$(xcode-select -p)/Platforms" && -d "$CLT/Frameworks/Testing.framework" ]]; then
    FLAGS=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
           -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
           -Xlinker -rpath -Xlinker "$CLT/Frameworks"
           -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
swift test "${FLAGS[@]}" "$@"
