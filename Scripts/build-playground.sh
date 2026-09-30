#!/bin/bash
# Builds the Kivy → NucleantUI playground (Tools/KivyToNucleantUI) for
# WebAssembly and bundles it as a static page.
#
#   Scripts/build-playground.sh [output-dir]
#
# Output defaults to .build/playground. Scripts/build-docs.sh calls this with
# a directory inside the documentation site, so the page is served next to
# the docs.
#
# Needs a swift.org toolchain and its matching WebAssembly Swift SDK (Xcode's
# toolchain cannot target wasm). With swiftly:
#
#   swiftly install 6.3.3
#   swift sdk install <the swift-6.3.3-RELEASE_wasm artifact bundle from swift.org>
#
# SWIFT_TOOLCHAIN (default 6.3.3) picks the swiftly toolchain; SWIFT_SDK
# overrides the SDK (default: the first non-embedded wasm SDK installed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/Tools/KivyToNucleantUI"
OUTPUT="$(mkdir -p "${1:-$ROOT/.build/playground}" && cd "${1:-$ROOT/.build/playground}" && pwd)"
PRODUCT="KivyToNucleantUIPlayground"
TOOLCHAIN="${SWIFT_TOOLCHAIN:-6.3.3}"

if command -v swiftly >/dev/null 2>&1; then
    swift() { swiftly run swift "$@" "+$TOOLCHAIN"; }
elif [ -x "$HOME/.swiftly/bin/swiftly" ]; then
    swift() { "$HOME/.swiftly/bin/swiftly" run swift "$@" "+$TOOLCHAIN"; }
fi

SDK="${SWIFT_SDK:-$(swift sdk list | grep -E '_wasm$' | head -1)}"
if [ -z "$SDK" ]; then
    echo "No WebAssembly Swift SDK installed (swift sdk list). See the top of $0." >&2
    exit 1
fi

echo "Building $PRODUCT with ${SDK}…"
cd "$TOOL"
swift package -c release --swift-sdk "$SDK" js --use-cdn --product "$PRODUCT"

BUILD_DIR="$TOOL/.build/plugins/PackageToJS/outputs/Package"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp -R "$BUILD_DIR"/. "$OUTPUT/"
cp "$TOOL/Playground/index.html" "$OUTPUT/index.html"

# Ship the module gzipped and inflate it in the browser: GitHub Pages serves
# .wasm uncompressed, and the converter is mostly the Swift runtime.
original=$(wc -c < "$OUTPUT/$PRODUCT.wasm")
gzip -9 -f "$OUTPUT/$PRODUCT.wasm"
perl -0pi -e "s|fetch\\(new URL\\(\"$PRODUCT.wasm\", import.meta.url\\)\\)|fetch(new URL(\"$PRODUCT.wasm.gz\", import.meta.url)).then(r => new Response(r.body.pipeThrough(new DecompressionStream(\"gzip\")), { headers: { \"Content-Type\": \"application/wasm\" } }))|" "$OUTPUT/index.js"
if ! grep -q "$PRODUCT.wasm.gz" "$OUTPUT/index.js"; then
    echo "Could not point index.js at $PRODUCT.wasm.gz — PackageToJS's loader changed." >&2
    exit 1
fi
compressed=$(wc -c < "$OUTPUT/$PRODUCT.wasm.gz")

echo "Playground: $OUTPUT ($((original / 1024)) KB wasm → $((compressed / 1024)) KB gzipped)"
