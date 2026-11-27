#!/usr/bin/env bash
# Local build (macOS only) — mirrors CI. Produces ios/SelfSign-adhoc.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 1/6 Fetch dependency sources"
# core/.cargo/config.toml patches with "../../.reference" (relative to core/),
# i.e. one level above this repository root.
mkdir -p "$ROOT/../.reference"
[ -d "$ROOT/../.reference/isideload" ] || git clone --depth 1 https://github.com/nab138/isideload.git "$ROOT/../.reference/isideload"
[ -d "$ROOT/../.reference/idevice" ] || git clone --depth 1 https://github.com/jkcoxson/idevice.git "$ROOT/../.reference/idevice"

echo "==> 2/6 Rust static library (device)"
rustup target add aarch64-apple-ios 2>/dev/null || true
(cd core && cargo build --release --target aarch64-apple-ios)

echo "==> 3/6 Generate Xcode project"
command -v xcodegen >/dev/null || brew install xcodegen
(cd ios && xcodegen generate --spec project.yml)

echo "==> 4/6 Archive (no signing)"
(cd ios && xcodebuild -project SelfSign.xcodeproj -scheme SelfSign \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/SelfSign.xcarchive CODE_SIGNING_ALLOWED=NO clean archive)

echo "==> 5/6 Ad-hoc sign + package IPA"
(cd ios && rm -rf build/Payload && mkdir -p build/Payload && \
  cp -R build/SelfSign.xcarchive/Products/Applications/SelfSign.app build/Payload/ && \
  codesign --force --deep --sign - build/Payload/SelfSign.app && \
  ditto -c -k --sequesterRsrc --keepParent build/Payload SelfSign-adhoc.ipa)

echo "==> 6/6 Done"
ls -lh ios/SelfSign-adhoc.ipa
echo "Install with:  ideviceinstaller -i ios/SelfSign-adhoc.ipa"
echo "Or via GitHub Actions: just push to main."
