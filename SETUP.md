# Set up ScriptMax on your Mac

ScriptMax is a native macOS teleprompter. This repository contains the source for the current app, not a notarized downloadable installer.

## Requirements

- An Apple Silicon Mac (M1 or newer), running macOS 27 or newer.
- Xcode 27 with its command-line tools selected, and Swift 6.2 or newer.
- Internet access for the pinned FluidAudio dependency and the first speech-model download. Allow several GB of free disk space and time for the initial download and build.
- A microphone. The camera is optional and is only needed for experimental gaze positioning.

Check the machine before building:

```sh
uname -m
sw_vers -productVersion
xcode-select -p
swift --version
```

The architecture should be `arm64`, and macOS must be at least 27. If tools are missing, install Xcode from Apple's official source, open it to complete its first-run setup, and select its command-line tools in Xcode Settings > Locations. Have the owner complete any license acceptance or administrator prompts. Do not silently upgrade macOS or substitute a Windows build.

## Download, build, and launch

Clone the GitHub repository into a new folder. From the cloned folder, run:

```sh
./scripts/test.sh
./scripts/build.sh
plutil -lint build/ScriptMax.app/Contents/Info.plist
codesign --verify --verbose build/ScriptMax.app
open build/ScriptMax.app
```

The build downloads the exact FluidAudio revision specified in `Package.swift` and produces a locally ad-hoc-signed app. Keep the app in this build folder initially; it downloads speech models into `build/SpeechModels` beside the app. The folder must be writable. No API key, paid speech account, or Apple developer membership is required to build locally.

## First use

1. Paste a script, or use `Practice-Script.txt`.
2. Click **Start from beginning** and allow Microphone access when macOS asks. Wait for the initial model download and for **Listening** before reading.
3. Read a few sentences aloud. Confirm that the displayed words advance, pause/resume works, and the prompt appears over the app you will use while presenting.
4. If access was denied, enable ScriptMax under System Settings > Privacy & Security > Microphone, then relaunch it.
5. Camera access is optional. Start with a fixed prompt near the camera; use **Calibrate eyes** only if you want to try gaze positioning.

The first model load can take time. Preserve any exact error if downloading or microphone startup fails. Tests and signing checks verify parts of the app, but a real spoken reading is needed to establish that it follows your voice correctly.

## Instructions for a coding agent

Inspect the Mac's architecture, macOS version, and selected Xcode/Swift tools first. If compatible, clone this repository into a fresh folder, follow the commands above, resolve ordinary build errors, and launch the resulting app. Preserve existing files and user work. Ask the owner to handle license, administrator, and microphone permission prompts as needed. Help them perform the first-use reading check and report what was actually verified. If the machine is incompatible, explain the exact requirement that fails before proposing system changes. Do not claim a successful build proves live speech following or webcam accuracy.
