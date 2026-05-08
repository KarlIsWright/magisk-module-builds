#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODULE_TEMPLATE_DIR="$SCRIPT_DIR/wireguard"
LOCAL_BUILD_SRC_DIR="$SCRIPT_DIR/wireguard_build"
WIREGUARD_TOOLS_SRC="$LOCAL_BUILD_SRC_DIR/wireguard-tools"
WIREGUARD_GO_SRC="$LOCAL_BUILD_SRC_DIR/wireguard-go"
TUN2SOCKS_SRC="$SCRIPT_DIR/tun2socks-build"

NDK_PATH=""
ANDROID_API="${ANDROID_API:-24}"
OUTPUT_ZIP=""
KEEP_BUILD=0
WORK_ROOT=""

find_ndk() {
  for search_dir in \
    "$HOME/.android/Sdk/ndk/" \
    "$HOME/Android/Sdk/ndk/" \
    "$HOME/Downloads/Android/Sdk/ndk/"; do
    if [ -d "$search_dir" ]; then
      latest_ndk=$(ls -1d "$search_dir"/* 2>/dev/null | sort -V | tail -n1 || true)
      if [ -n "$latest_ndk" ] && [ -d "$latest_ndk" ]; then
        echo "$latest_ndk"
        return 0
      fi
    fi
  done
  return 1
}

show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Builds a WireGuard Magisk module (arm64) in a temporary wireguard_build workspace,
then outputs a flashable zip named from module.prop (default: wireguard-v4.2.8-magisk.zip).

Options:
  --NDK=PATH                 Android NDK path (auto-detected if omitted)
  --api=LEVEL                Android API level for C/C++ builds (default: $ANDROID_API)
  --output=PATH              Output zip path (default: <script_dir>/wireguard-<version>-magisk.zip)
  --wireguard-tools-src=PATH Path to wireguard-tools source (default: $WIREGUARD_TOOLS_SRC)
  --wireguard-go-src=PATH    Path to wireguard-go source (default: $WIREGUARD_GO_SRC)
  --tun2socks-src=PATH       Path to tun2socks source (default: $TUN2SOCKS_SRC)
  --module-template=PATH     Module template dir (default: $MODULE_TEMPLATE_DIR)
  --keep-build               Keep temporary build workspace
  --help                     Show this help message
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ -n "${WORK_ROOT:-}" ] && [ -d "$WORK_ROOT" ] && [ "$KEEP_BUILD" -eq 0 ]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --NDK=*)
      NDK_PATH="${1#--NDK=}"
      shift
      ;;
    --api=*)
      ANDROID_API="${1#--api=}"
      shift
      ;;
    --output=*)
      OUTPUT_ZIP="${1#--output=}"
      shift
      ;;
    --wireguard-tools-src=*)
      WIREGUARD_TOOLS_SRC="${1#--wireguard-tools-src=}"
      shift
      ;;
    --wireguard-go-src=*)
      WIREGUARD_GO_SRC="${1#--wireguard-go-src=}"
      shift
      ;;
    --tun2socks-src=*)
      TUN2SOCKS_SRC="${1#--tun2socks-src=}"
      shift
      ;;
    --module-template=*)
      MODULE_TEMPLATE_DIR="${1#--module-template=}"
      shift
      ;;
    --keep-build)
      KEEP_BUILD=1
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

echo "==> Checking prerequisites"
for c in git make go zip sed awk grep ls sort head mktemp find; do
  require_cmd "$c"
done

[ -d "$MODULE_TEMPLATE_DIR" ] || {
  echo "Module template directory not found: $MODULE_TEMPLATE_DIR" >&2
  exit 1
}
[ -d "$WIREGUARD_TOOLS_SRC" ] || {
  echo "wireguard-tools source directory not found: $WIREGUARD_TOOLS_SRC" >&2
  exit 1
}
[ -d "$WIREGUARD_GO_SRC" ] || {
  echo "wireguard-go source directory not found: $WIREGUARD_GO_SRC" >&2
  exit 1
}
[ -d "$TUN2SOCKS_SRC" ] || {
  echo "tun2socks source directory not found: $TUN2SOCKS_SRC" >&2
  exit 1
}

MODULE_VERSION=$(sed -n 's/^version=//p' "$MODULE_TEMPLATE_DIR/module.prop" | head -n1)
[ -n "$MODULE_VERSION" ] || {
  echo "Unable to read module version from $MODULE_TEMPLATE_DIR/module.prop" >&2
  exit 1
}
case "$MODULE_VERSION" in
  v*) ;;
  *) MODULE_VERSION="v$MODULE_VERSION" ;;
esac

if [ -z "$OUTPUT_ZIP" ]; then
  OUTPUT_ZIP="$SCRIPT_DIR/wireguard-${MODULE_VERSION}-magisk.zip"
fi
case "$OUTPUT_ZIP" in
  /*) ;;
  *) OUTPUT_ZIP="$SCRIPT_DIR/$OUTPUT_ZIP" ;;
esac

if [ -n "$NDK_PATH" ]; then
  [ -d "$NDK_PATH" ] || {
    echo "Error: NDK path does not exist: $NDK_PATH" >&2
    exit 1
  }
else
  NDK_PATH=$(find_ndk || true)
  if [ -z "$NDK_PATH" ]; then
    echo "Error: Android NDK not found in standard locations." >&2
    echo "Use --NDK=/path/to/ndk to specify it explicitly." >&2
    exit 1
  fi
fi

case "$ANDROID_API" in
  ''|*[!0-9]*)
    echo "Error: --api must be numeric (received: $ANDROID_API)" >&2
    exit 1
    ;;
esac

PREBUILT_BASE="$NDK_PATH/toolchains/llvm/prebuilt"
[ -d "$PREBUILT_BASE" ] || {
  echo "Error: NDK prebuilt toolchain directory not found: $PREBUILT_BASE" >&2
  exit 1
}

TOOLCHAIN_ROOT=""
for candidate in "$PREBUILT_BASE/linux-x86_64" "$PREBUILT_BASE/darwin-x86_64" "$PREBUILT_BASE/darwin-arm64"; do
  if [ -d "$candidate" ]; then
    TOOLCHAIN_ROOT="$candidate"
    break
  fi
done
if [ -z "$TOOLCHAIN_ROOT" ]; then
  TOOLCHAIN_ROOT=$(find "$PREBUILT_BASE" -mindepth 1 -maxdepth 1 -type d | sort | head -n1 || true)
fi
[ -n "$TOOLCHAIN_ROOT" ] || {
  echo "Error: could not locate an NDK prebuilt toolchain under $PREBUILT_BASE" >&2
  exit 1
}

TOOLCHAIN_BIN="$TOOLCHAIN_ROOT/bin"
SYSROOT="$TOOLCHAIN_ROOT/sysroot"
CC="$TOOLCHAIN_BIN/aarch64-linux-android${ANDROID_API}-clang"
CXX="$TOOLCHAIN_BIN/aarch64-linux-android${ANDROID_API}-clang++"
AR="$TOOLCHAIN_BIN/llvm-ar"
STRIP="$TOOLCHAIN_BIN/llvm-strip"

[ -x "$CC" ] || {
  echo "Error: compiler not found: $CC" >&2
  exit 1
}
[ -x "$CXX" ] || {
  echo "Error: compiler not found: $CXX" >&2
  exit 1
}
[ -x "$AR" ] || {
  echo "Error: archiver not found: $AR" >&2
  exit 1
}
[ -x "$STRIP" ] || {
  echo "Error: strip tool not found: $STRIP" >&2
  exit 1
}
[ -d "$SYSROOT" ] || {
  echo "Error: sysroot not found: $SYSROOT" >&2
  exit 1
}

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo "==> Using Android NDK: $NDK_PATH"
echo "==> Using toolchain: $TOOLCHAIN_ROOT"
echo "==> Android API: $ANDROID_API"
echo "==> Module version: $MODULE_VERSION"
echo "==> Output zip: $OUTPUT_ZIP"

WORK_ROOT=$(mktemp -d "$SCRIPT_DIR/wireguard_build.XXXXXX")
TOOLS_WORK="$WORK_ROOT/wireguard-tools"
GO_WORK="$WORK_ROOT/wireguard-go"
TUN2SOCKS_WORK="$WORK_ROOT/tun2socks"
MODULE_STAGE="$WORK_ROOT/wireguard"
BIN_STAGE="$WORK_ROOT/bin"

mkdir -p "$TOOLS_WORK" "$GO_WORK" "$TUN2SOCKS_WORK" "$MODULE_STAGE" "$BIN_STAGE"

echo "==> Preparing temporary build workspace: $WORK_ROOT"
cp -a "$WIREGUARD_TOOLS_SRC/." "$TOOLS_WORK/"
cp -a "$WIREGUARD_GO_SRC/." "$GO_WORK/"
cp -a "$TUN2SOCKS_SRC/." "$TUN2SOCKS_WORK/"
cp -a "$MODULE_TEMPLATE_DIR/." "$MODULE_STAGE/"

WG_LDFLAGS="-fPIE -pie --sysroot=$SYSROOT"

echo "==> Building wg"
make -C "$TOOLS_WORK/src" clean >/dev/null 2>&1 || true
make -C "$TOOLS_WORK/src" -j"$JOBS" CC="$CC" AR="$AR" PLATFORM=linux LDFLAGS="$WG_LDFLAGS" wg
cp -f "$TOOLS_WORK/src/wg" "$BIN_STAGE/wg"

echo "==> Building wg-quick (Android)"
"$CC" -O2 -fPIE -fPIC -std=gnu99 -D_GNU_SOURCE --sysroot="$SYSROOT" "$TOOLS_WORK/src/wg-quick/android.c" -o "$BIN_STAGE/wg-quick" $WG_LDFLAGS -ldl

echo "==> Building wireguard-go"
(
  cd "$GO_WORK"
  GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$CC" CXX="$CXX" \
    CGO_CFLAGS="--sysroot=$SYSROOT" \
    CGO_LDFLAGS="--sysroot=$SYSROOT -fPIE -pie" \
    go build -trimpath -o "$BIN_STAGE/wireguard-go" .
)

echo "==> Building tun2socks"
(
  cd "$TUN2SOCKS_WORK"
  GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$CC" CXX="$CXX" \
    CGO_CFLAGS="--sysroot=$SYSROOT" \
    CGO_LDFLAGS="--sysroot=$SYSROOT -fPIE -pie" \
    go build -trimpath -o "$BIN_STAGE/tun2socks" .
)

echo "==> Stripping binaries"
"$STRIP" "$BIN_STAGE/wg" "$BIN_STAGE/wg-quick" "$BIN_STAGE/wireguard-go" "$BIN_STAGE/tun2socks" || true

echo "==> Staging module files"
mkdir -p "$MODULE_STAGE/arch/arm64/bin"
cp -f "$BIN_STAGE/wg" "$MODULE_STAGE/arch/arm64/bin/wg"
cp -f "$BIN_STAGE/wg-quick" "$MODULE_STAGE/arch/arm64/bin/wg-quick"
cp -f "$BIN_STAGE/wireguard-go" "$MODULE_STAGE/arch/arm64/bin/wireguard-go"
cp -f "$BIN_STAGE/tun2socks" "$MODULE_STAGE/arch/arm64/bin/tun2socks"
chmod 0755 "$MODULE_STAGE/arch/arm64/bin/wg" \
           "$MODULE_STAGE/arch/arm64/bin/wg-quick" \
           "$MODULE_STAGE/arch/arm64/bin/wireguard-go" \
           "$MODULE_STAGE/arch/arm64/bin/tun2socks"
chmod 0755 "$MODULE_STAGE/install.sh" \
           "$MODULE_STAGE/uninstall.sh" \
           "$MODULE_STAGE/common/service.sh" \
           "$MODULE_STAGE/common/wireguardd.init" \
           "$MODULE_STAGE/META-INF/com/google/android/update-binary"

echo "==> Creating flashable zip"
rm -f "$OUTPUT_ZIP"
(cd "$MODULE_STAGE" && zip -qr "$OUTPUT_ZIP" .)

[ -f "$OUTPUT_ZIP" ] || {
  echo "Build completed but no zip was produced: $OUTPUT_ZIP" >&2
  exit 1
}

echo "==> Output created: $OUTPUT_ZIP"
if [ "$KEEP_BUILD" -eq 1 ]; then
  echo "==> Temporary workspace kept at: $WORK_ROOT"
else
  echo "==> Temporary workspace removed"
fi