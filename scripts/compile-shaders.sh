#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/AgentGlanceApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/AgentGlanceApp/Resources
xcrun -sdk macosx metal \
    Sources/AgentGlanceApp/Ripple.metal \
    -o Sources/AgentGlanceApp/Resources/default.metallib
echo "Wrote Sources/AgentGlanceApp/Resources/default.metallib"
