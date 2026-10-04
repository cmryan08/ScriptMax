#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -module-cache-path build/ModuleCache -swift-version 5 Sources/ScriptMax/ScriptFollower.swift Sources/ScriptMax/ConfidentFollower.swift Sources/ScriptMax/PromptLayout.swift Sources/ScriptMax/ReadingPacer.swift Sources/ScriptMax/TranscriptAccumulator.swift Sources/ScriptMax/GazeTracker.swift Tests/main.swift -o build/checks -framework AppKit -framework AVFoundation -framework Vision
build/checks
