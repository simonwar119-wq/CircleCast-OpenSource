#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/module-cache TestArtifacts
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export CIRCLECAST_TEST_OUTPUT="$PWD/TestArtifacts"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" 2>&1 | tee TestArtifacts/test-log.txt
