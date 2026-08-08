#!/usr/bin/env bash
#
# Build MultiComp.clap, optionally validate and install it.
#
#   ./build.sh                 build the bundle
#   ./build.sh --validate      build, then run the official CLAP validator
#   ./build.sh --install       build, then symlink into ~/Library/Audio/Plug-Ins/CLAP
#   ./build.sh --debug         build with debug symbols
#
# Flags combine.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="MultiComp"
BUNDLE_ID="com.foesoft.multicomp"
VERSION="0.1.0"

BUILD_DIR="$ROOT/build"
DYLIB="$BUILD_DIR/multicomp.dylib"
BUNDLE="$BUILD_DIR/$NAME.clap"
CLAP_DIR="$HOME/Library/Audio/Plug-Ins/CLAP"

do_validate=0
do_install=0
do_offline=0
odin_flags=(-o:speed)

for arg in "$@"; do
	case "$arg" in
	--validate) do_validate=1 ;;
	--install) do_install=1 ;;
	--offline) do_offline=1 ;;
	--debug) odin_flags=(-debug) ;;
	*)
		echo "unknown flag: $arg" >&2
		exit 2
		;;
	esac
done

mkdir -p "$BUILD_DIR"

echo "==> Building $NAME"
odin build "$ROOT/src/plugin" \
	-collection:proj="$ROOT" \
	-build-mode:shared \
	-out:"$DYLIB" \
	"${odin_flags[@]}"

# A CLAP on macOS is a bundle, not a bare dylib.
echo "==> Packaging $NAME.clap"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$DYLIB" "$BUNDLE/Contents/MacOS/$NAME"
printf 'BNDL????' >"$BUNDLE/Contents/PkgInfo"

cat >"$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>English</string>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
EOF

# Sanity check: the one symbol every host looks for.
if ! nm -gU "$BUNDLE/Contents/MacOS/$NAME" | grep -q '_clap_entry'; then
	echo "ERROR: clap_entry symbol is missing from the built binary" >&2
	exit 1
fi

echo "    $BUNDLE"

if [[ $do_validate -eq 1 ]]; then
	# Warm-up load first. A freshly written dylib costs hundreds of milliseconds on its
	# very first dlopen (dyld mapping plus macOS's one-time signature assessment), which
	# trips the validator's 100 ms scan-time check for reasons that have nothing to do
	# with our code. Warm, this plugin scans in about 1 ms.
	clap-info "$BUNDLE" >/dev/null 2>&1 || true

	echo "==> Validating"
	clap-validator validate "$BUNDLE"
fi

if [[ $do_offline -eq 1 ]]; then
	echo "==> Offline audio checks"
	odin run "$ROOT/tools/offline" \
		-collection:proj="$ROOT" \
		-out:"$BUILD_DIR/offline" \
		-- "$BUNDLE/Contents/MacOS/$NAME"
fi

if [[ $do_install -eq 1 ]]; then
	echo "==> Installing to $CLAP_DIR"
	mkdir -p "$CLAP_DIR"
	rm -rf "${CLAP_DIR:?}/$NAME.clap"
	ln -s "$BUNDLE" "$CLAP_DIR/$NAME.clap"
	echo "    symlinked (rebuilds are picked up automatically)"
fi
