#!/bin/zsh
# Builds FoamMaster for Apple silicon (arm64) and Intel (x86_64) and zips each as
# build/release/FoamMaster-<version>-build<build>-macOS-<arch>.zip (version and build from build_app.sh).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^VERSION=//p' build_app.sh)
BUILD=$(sed -n 's/^BUILD=//p' build_app.sh)
mkdir -p build/release
for ARCH in arm64 x86_64; do
  ./build_app.sh "$ARCH"
  ZIP=build/release/FoamMaster-$VERSION-build$BUILD-macOS-$ARCH.zip
  rm -f "$ZIP"
  (cd "build/$ARCH" && ditto -c -k --sequesterRsrc --keepParent FoamMaster.app "../../$ZIP")
  echo "Packed $ZIP ($(lipo -archs "build/$ARCH/FoamMaster.app/Contents/MacOS/FoamMaster"))"
done
