Recommendation on Approach: Prefer Swift Package Manager (SPM) Over Submodules

For a Swift/iOS project like your Silo fork:





SPM is the modern, recommended way (cleaner, native Xcode integration, automatic dependency resolution).



Git submodules are more heavyweight — they embed the full repo history and require extra commands on clone (git submodule update --init --recursive). Use them only if a library isn't available as an SPM package or if you need to heavily modify the source.

For your specific repos:





VoxRT (voxrt-silero-ios & voxrt-asr-ios)





Add via SPM if they support it (most recent iOS speech packages do).



If not packaged, then use submodule for the fork you linked.



Strong for VAD + potential Thai FastConformer port.



exPHAT/SwiftWhisper





Excellent lightweight wrapper around whisper.cpp. Add via SPM (preferred). Great for quick prototyping with biodatlab/Typhoon Whisper models and built-in translation.



soniqo/speech-swift





Very promising modern toolkit (MLX + CoreML, ASR/TTS/VAD/diarization, on-device for Apple Silicon). Add via SPM — it explicitly supports it.

Overall: Start with SPM for all three. Fall back to submodules only if SPM integration fails.

How to Add as Submodules in GitHub (Step-by-Step)







Use hosted macOS runners (macos-latest or macos-14 / macos-15). These come pre-installed with Xcode and the necessary tools. No self-hosted Mac needed initially.

1. Basic Workflow Structure (.github/workflows/ios-build.yml)

YAML

name: iOS Build & Test

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: macos-latest   # or macos-14 for more control
    
    steps:
      - name: Checkout with submodules
        uses: actions/checkout@v4
        with:
          submodules: recursive   # Critical for your dependencies

      - name: Select Xcode version
        run: |
          sudo xcode-select -switch /Applications/Xcode.app
          xcodebuild -version

      - name: Cache Swift Package dependencies
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          key: ${{ runner.os }}-spm-${{ hashFiles('**/Package.resolved') }}
          restore-keys: ${{ runner.os }}-spm-

      - name: Build Project
        run: |
          xcodebuild clean build \
            -project Silo.xcodeproj \   # or .xcworkspace if using CocoaPods
            -scheme YourAppScheme \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            CODE_SIGNING_ALLOWED=NO   # For CI, disable signing initially

      - name: Run Tests (optional)
        run: |
          xcodebuild test \
            -project Silo.xcodeproj \
            -scheme YourAppScheme \
            -destination 'platform=iOS Simulator,name=iPhone 16'