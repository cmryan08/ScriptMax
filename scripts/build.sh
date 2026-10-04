#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ScriptMax.app/Contents/MacOS
mkdir -p build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
swift build --disable-sandbox --scratch-path build/SwiftPM -c release --product ScriptMax
cp build/SwiftPM/release/ScriptMax build/ScriptMax.app/Contents/MacOS/ScriptMax
cp Info.plist build/ScriptMax.app/Contents/Info.plist
mkdir -p build/ScriptMax.app/Contents/Resources
for bundle in build/SwiftPM/release/*.bundle; do
    cp -R "$bundle" build/ScriptMax.app/Contents/Resources/
done
codesign --force --sign - --identifier com.chrisryan.ScriptMax build/ScriptMax.app
