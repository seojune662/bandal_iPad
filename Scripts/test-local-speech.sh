#!/bin/bash
set -euo pipefail

# First resolve/build the Xcode project with -clonedSourcePackagesDirPath .build/SourcePackages.
# Supply the official pinned Zipformer files and test_wavs/0.wav (renamed 0.wav).
# No user recording or microphone is accessed by this test.
task_root=$(cd "$(dirname "$0")/.." && pwd)
fixture_dir=${1:-"$task_root/.build/SpeechFixtures/zipformer-ko"}
packages="$task_root/.build/SourcePackages"
sherpa_framework="$packages/artifacts/sherpa-onnx/SherpaOnnxMacOS/sherpa-onnx.xcframework/macos-arm64_x86_64"
onnx_framework="$packages/artifacts/onnxruntime-libs/OnnxruntimeMacOS/onnxruntime.xcframework/macos-arm64_x86_64"
temporary=$(mktemp -d /tmp/bandal-native-speech.XXXXXX)
trap 'rm -rf "$temporary"' EXIT

xcrun swiftc -emit-module -emit-library -swift-version 5 -DSWIFT_PACKAGE \
  -module-name SherpaOnnx -module-cache-path "$temporary/cache" \
  -F "$sherpa_framework" -F "$onnx_framework" \
  -framework SherpaOnnxC -framework onnxruntime -lc++ \
  "$packages/checkouts/sherpa-onnx/swift-api-examples/SherpaOnnx.swift" \
  -emit-module-path "$temporary/SherpaOnnx.swiftmodule" -o "$temporary/libSherpaOnnx.dylib"

xcrun swiftc -swift-version 5 -module-cache-path "$temporary/cache" \
  -I "$temporary" -L "$temporary" -F "$sherpa_framework" -F "$onnx_framework" \
  -lSherpaOnnx -Xlinker -rpath -Xlinker "$temporary" \
  "$task_root/App/Recording/PCMRecordingWriter.swift" \
  "$task_root/App/Recording/LocalSpeech.swift" \
  "$task_root/Tests/NativeSpeechFixture.swift" -o "$temporary/speech-fixture"
"$temporary/speech-fixture" "$fixture_dir"
