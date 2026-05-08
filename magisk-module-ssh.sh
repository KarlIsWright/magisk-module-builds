#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK_ROOT="$SCRIPT_DIR/Build_MagiskSSH"
REPO_URL="https://gitlab.com/d4rcm4rc/MagiskSSH"
OPENSSL_VER="openssl-4.0.0"
OPENSSH_VER="openssh-10.3p1"
DEFAULT_MODULE_VERSION="v0.27.1"
TARGET_ARCH=""
NDK_PATH=""
OVERRIDE_VERSION="$DEFAULT_MODULE_VERSION"
BUILD_VANILLA=0
HARDENED_CFLAGS="-O2 -fPIE -D_FORTIFY_SOURCE=3 -fno-strict-overflow -fno-delete-null-pointer-checks"
HARDENED_LDFLAGS="-pie -Wl,-z,text"

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

Options:
  --arch=ARCH         Build for specific architecture (default: all)
  --NDK=PATH          Specify Android NDK path (auto-detected if not provided)
  --version=VERSION   Override output/module version (default: $DEFAULT_MODULE_VERSION)
  --openssl=VERSION   Override OpenSSL version (default: $OPENSSL_VER)
  --openssh=VERSION   Override OpenSSH version (default: $OPENSSH_VER)
  --vanilla           Build upstream without tunnel patches
  --help              Show this help message

Available architectures:
  arm64   (aarch64 - for Pixel 10a)
  x86_64  (Intel 64-bit)
  x86     (Intel 32-bit)
  armv7   (ARM 32-bit)

NDK Search Locations (if --NDK not specified):
  ~/.android/Sdk/ndk/
  ~/Android/Sdk/ndk/
  ~/Downloads/Android/Sdk/ndk/

Examples:
  $0 --arch=arm64
  $0 --arch=arm64 --version=v0.27.1
  $0 --arch=arm64 --openssl=3.6.2 --openssh=10.2p1
  $0 --arch=arm64 --NDK=/path/to/ndk/25.2.9519653
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch=*)
      TARGET_ARCH="${1#--arch=}"
      shift
      ;;
    --NDK=*)
      NDK_PATH="${1#--NDK=}"
      shift
      ;;
    --version=*)
      OVERRIDE_VERSION="${1#--version=}"
      shift
      ;;
    --openssl=*)
      OPENSSL_VER="${1#--openssl=}"
      case "$OPENSSL_VER" in
        openssl-*) ;;
        *) OPENSSL_VER="openssl-$OPENSSL_VER" ;;
      esac
      shift
      ;;
    --openssh=*)
      OPENSSH_VER="${1#--openssh=}"
      case "$OPENSSH_VER" in
        openssh-*) ;;
        *) OPENSSH_VER="openssh-$OPENSSH_VER" ;;
      esac
      shift
      ;;
    --vanilla)
      BUILD_VANILLA=1
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

if [ -n "$NDK_PATH" ]; then
  if [ ! -d "$NDK_PATH" ]; then
    echo "Error: NDK path does not exist: $NDK_PATH" >&2
    exit 1
  fi
else
  NDK_PATH=$(find_ndk || true)
  if [ -z "$NDK_PATH" ]; then
    echo "Error: Android NDK not found in standard locations." >&2
    echo "Use --NDK=/path/to/ndk to specify it explicitly." >&2
    exit 1
  fi
fi

ANDROID_ROOT="${ANDROID_ROOT:-$NDK_PATH}"
echo "==> Using Android NDK: $ANDROID_ROOT"

cleanup() {
  if [ -n "${TMP_CLONE_DIR:-}" ] && [ -d "$TMP_CLONE_DIR" ]; then
    rm -rf "$TMP_CLONE_DIR"
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT INT TERM

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

bump_minor_version() {
  in="$1"
  v="${in#v}"
  IFS='.' read -r a b c <<EOF
$v
EOF
  [ -n "${a:-}" ] || {
    echo "Unable to parse version: $in" >&2
    exit 1
  }
  [ -n "${b:-}" ] || b=0
  [ -n "${c:-}" ] || c=0
  b=$((b + 1))
  echo "v${a}.${b}.0"
}

add_tunnel_support() {
  src="$1"

  python3 - "$src/openbsd-compat/port-net.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = "#if defined(SSH_TUN_LINUX)\n"
replacement = "#if defined(SSH_TUN_LINUX) && !defined(CUSTOM_SYS_TUN_OPEN)\n"
if replacement not in text:
    if needle not in text:
        raise SystemExit(f"SSH_TUN_LINUX block not found in {path}")
    text = text.replace(needle, replacement, 1)
path.write_text(text)
PY
}
latest_openssh_patch() {
  find patches -maxdepth 1 -type f -name 'openssh-*.patch' 2>/dev/null \
    | sed 's#^patches/##; s#\.patch$##' \
    | grep -E '^openssh-[0-9]+\.[0-9]+p[0-9]+$' \
    | sort -V \
    | tail -n1
}
repair_makefile_android_tweaks() {
  src="$1"

  python3 - "$src/Makefile.in" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

targets = [
    "LIBSSH_OBJS",
    "SSHOBJS",
    "SSHDOBJS",
    "SSHD_SESSION_OBJS",
    "SSHD_AUTH_OBJS",
]

lines = text.splitlines()

for target in targets:
    start = next((i for i, line in enumerate(lines) if line.startswith(target + "=")), None)
    if start is None:
        raise SystemExit(f"{target} not found in {path}")

    end = start
    while end < len(lines) - 1 and lines[end].rstrip().endswith("\\"):
        end += 1

    if any("android-tweaks.o" in line for line in lines[start:end + 1]):
        continue

    last = lines[end]
    lines[end] = last + " \\"
    lines.insert(end + 1, "\tandroid-tweaks.o")

path.write_text("\n".join(lines) + "\n")
PY
}

add_pwent_decls_to_android_tweaks() {
  src="$1"

  python3 - "$src/android-tweaks.h" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(f"Missing {path}; base patch did not add android-tweaks.h")

text = path.read_text()
needed = (
    "void setpwent(void);",
    "void endpwent(void);",
    "struct passwd *getpwent(void);",
    "void endgrent(void);",
)
if all(decl in text for decl in needed):
    sys.exit(0)

lines = text.splitlines()
try:
    insert_idx = next(i for i, line in enumerate(lines) if line.strip() == "#endif")
except StopIteration:
    raise SystemExit(f"Could not find closing #endif in {path}")

extra = [decl for decl in needed if decl not in text]
for offset, decl in enumerate(extra):
    lines.insert(insert_idx + offset, decl)
lines.insert(insert_idx + len(extra), "")

path.write_text("\n".join(lines) + "\n")
PY
}

generate_openssh_patch_from_base() {
  patch_file="$1"
  work_dir="$2"
  archive="$3"
  base_patch="$4"
  add_tunnel="$5"

  rm -rf "$work_dir/orig" "$work_dir/mod"
  mkdir -p "$work_dir/orig" "$work_dir/mod"
  tar -xzf "$archive" -C "$work_dir/orig"
  tar -xzf "$archive" -C "$work_dir/mod"
  if [ -n "$base_patch" ] && [ -f "$base_patch" ]; then
    cp "$base_patch" "$work_dir/base.patch"
    echo "==> Applying base OpenSSH patch: $(basename "$base_patch")"
    if ! (cd "$work_dir/mod/$OPENSSH_VER" && patch -p1 -F 3 < "$work_dir/base.patch"); then
      echo "==> Base patch did not apply cleanly; attempting known compatibility repairs"
    fi
    repair_makefile_android_tweaks "$work_dir/mod/$OPENSSH_VER"
    add_pwent_decls_to_android_tweaks "$work_dir/mod/$OPENSSH_VER"
    find "$work_dir/mod/$OPENSSH_VER" -type f -name '*.orig' -delete
    reject_files=$(find "$work_dir/mod/$OPENSSH_VER" -type f -name '*.rej' -print)
    if [ -n "$reject_files" ]; then
      unexpected_rejects=$(printf '%s\n' "$reject_files" | grep -v '/Makefile.in.rej$' || true)
      if [ -n "$unexpected_rejects" ]; then
        echo "Unable to adapt base patch; unexpected rejects:" >&2
        printf '%s\n' "$unexpected_rejects" >&2
        exit 1
      fi
      rm -f "$work_dir/mod/$OPENSSH_VER/Makefile.in.rej"
    fi
  fi

  if [ "$add_tunnel" -eq 1 ]; then
    echo "==> Adding tunnel support to OpenSSH patch"
    add_tunnel_support "$work_dir/mod/$OPENSSH_VER"
  fi
  diff -ruN "$work_dir/orig/$OPENSSH_VER" "$work_dir/mod/$OPENSSH_VER" > "$patch_file" || true
  sed -i "s|$work_dir/orig/$OPENSSH_VER|a|g; s|$work_dir/mod/$OPENSSH_VER|b|g" "$patch_file"
}

prepare_openssh_patch() {
  work_dir="$1"
  archive="$2"
  target_patch="patches/${OPENSSH_VER}.patch"
  exact_patch=""
  base_patch=""
  add_tunnel=1

  if [ -f "$target_patch" ]; then
    exact_patch="$target_patch"
  fi

  if [ "$BUILD_VANILLA" -eq 1 ]; then
    add_tunnel=0
    if [ -n "$exact_patch" ]; then
      echo "==> Using existing OpenSSH patch: $(basename "$exact_patch")"
      return 0
    fi
  fi

  if [ -n "$exact_patch" ]; then
    base_patch="$exact_patch"
  else
    latest_patch=$(latest_openssh_patch)
    [ -n "$latest_patch" ] || {
      echo "No OpenSSH patch found to adapt for $OPENSSH_VER" >&2
      exit 1
    }
    base_patch="patches/${latest_patch}.patch"
    echo "==> No exact patch for $OPENSSH_VER; adapting $(basename "$base_patch")"
  fi

  if [ "$add_tunnel" -eq 1 ]; then
    echo "==> Generating ${OPENSSH_VER}.patch from base patch plus tunnel support"
  else
    echo "==> Generating ${OPENSSH_VER}.patch from adapted upstream patch"
  fi
  generate_openssh_patch_from_base "$target_patch" "$work_dir" "$archive" "$base_patch" "$add_tunnel"
}

download_source_archive() {
  package="$1"
  url="$2"
  archive="${package}.tar.gz"
  checksum_file="checksums/${archive}.sha512"

  wget -q "$url" -O "dl/$archive"

  if [ -f "$checksum_file" ]; then
    echo "==> Using existing checksum: $checksum_file"
  else
    echo "==> No existing checksum for $archive; generating one"
    (cd dl && sha512sum "$archive") > "$checksum_file"
  fi

  (cd dl && sha512sum -c "../$checksum_file")
}

openssl_libcrypto_version() {
  v="${1#openssl-}"
  case "$v" in
    1.1.*) echo "1.1" ;;
    1.0.*) echo "1.0.0" ;;
    *) echo "${v%%.*}" ;;
  esac
}

apply_hardening_flags() {
  cflags="$1"
  ldflags="$2"

  python3 - "$cflags" "$ldflags" <<'PY'
from pathlib import Path
import sys

cflags, ldflags = sys.argv[1], sys.argv[2]

main = Path("main.mk")
lines = main.read_text().splitlines()
found_cflags = False
found_ldflags = False
found_ld = False

for i, line in enumerate(lines):
    if line.startswith("CFLAGS=") or line.startswith("CFLAGS:="):
        lines[i] = f"CFLAGS={cflags}"
        found_cflags = True
    elif line.startswith("LDFLAGS=") or line.startswith("LDFLAGS:="):
        lines[i] = f"LDFLAGS={ldflags}"
        found_ldflags = True
    elif line.startswith("LD=") or line.startswith("LD:="):
        lines[i] = "LD=$(CC)"
        found_ld = True

if not found_cflags or not found_ldflags or not found_ld:
    raise SystemExit(f"Could not find CFLAGS/LDFLAGS/LD in {main}")

main.write_text("\n".join(lines) + "\n")

openssl = Path("openssl.mk")
lines = openssl.read_text().splitlines()
for i, line in enumerate(lines):
    if "ANDROID_NDK_ROOT=$(ANDROID_ROOT)" in line:
        window = lines[i + 1:i + 5]
        if not any('CFLAGS="$(CFLAGS)"' in item for item in window):
            indent = line[:len(line) - len(line.lstrip())]
            lines.insert(i + 1, f'{indent}CFLAGS="$(CFLAGS)" \\')
            lines.insert(i + 2, f'{indent}LDFLAGS="$(LDFLAGS)" \\')
        break
else:
    raise SystemExit(f"Could not find Android NDK environment block in {openssl}")

openssl.write_text("\n".join(lines) + "\n")
PY
}

limit_magisk_module_to_arch() {
  arch="$1"

  python3 - "$arch" <<'PY'
from pathlib import Path
import sys

arch = sys.argv[1]
path = Path("magisk_module.mk")
text = path.read_text()

old_binaries = """$(BUILD_DIR)/module/stamp.module-binaries: $(BUILD_DIR)/module/stamp.module-created \\
                                           $(INSTALLED_FILES_arm)                   \\
                                           $(INSTALLED_FILES_arm64)                 \\
                                           $(INSTALLED_FILES_x86)                   \\
                                           $(INSTALLED_FILES_x86_64)
\tcp -r $(BUILD_DIR)/arm/usr    $(BUILD_DIR)/module/magisk_ssh/arch/arm
\tcp -r $(BUILD_DIR)/arm64/usr  $(BUILD_DIR)/module/magisk_ssh/arch/arm64
\tcp -r $(BUILD_DIR)/x86/usr    $(BUILD_DIR)/module/magisk_ssh/arch/x86
\tcp -r $(BUILD_DIR)/x86_64/usr $(BUILD_DIR)/module/magisk_ssh/arch/x86_64
\ttouch $(BUILD_DIR)/module/stamp.module-binaries
"""

new_binaries = f"""$(BUILD_DIR)/module/stamp.module-binaries: $(BUILD_DIR)/module/stamp.module-created \\
                                           $(INSTALLED_FILES_{arch})
\tcp -r $(BUILD_DIR)/{arch}/usr $(BUILD_DIR)/module/magisk_ssh/arch/{arch}
\ttouch $(BUILD_DIR)/module/stamp.module-binaries
"""

old_init_dep = """$(BUILD_DIR)/module/stamp.module-initscript: $(BUILD_DIR)/arm/openssh/stamp.built     \\
                                             $(BUILD_DIR)/module/stamp.module-created
"""
new_init_dep = f"""$(BUILD_DIR)/module/stamp.module-initscript: $(BUILD_DIR)/{arch}/openssh/stamp.built     \\
                                             $(BUILD_DIR)/module/stamp.module-created
"""

old_init_src = "\t    $(BUILD_DIR)/arm/openssh/opensshd.init     \\"
new_init_src = f"\t    $(BUILD_DIR)/{arch}/openssh/opensshd.init     \\"

if old_binaries not in text:
    raise SystemExit("Could not find module-binaries block in magisk_module.mk")
text = text.replace(old_binaries, new_binaries, 1)

if old_init_dep not in text:
    raise SystemExit("Could not find module-initscript dependency block in magisk_module.mk")
text = text.replace(old_init_dep, new_init_dep, 1)

if old_init_src not in text:
    raise SystemExit("Could not find opensshd.init source path in magisk_module.mk")
text = text.replace(old_init_src, new_init_src, 1)

path.write_text(text)
PY
}

echo "==> Checking prerequisites"
for c in git sed awk grep sha512sum make tar wget unzip zip python3 diff patch; do
  require_cmd "$c"
done

mkdir -p "$WORK_ROOT"
TMP_CLONE_DIR=$(mktemp -d "$WORK_ROOT/.tmp.XXXXXX")

echo "==> Cloning upstream MagiskSSH"
git clone --depth 1 "$REPO_URL" "$TMP_CLONE_DIR/MagiskSSH"
cd "$TMP_CLONE_DIR/MagiskSSH"

UPSTREAM_VERSION=$(sed -n 's/^version=//p' module_data/module.prop | head -n1)
[ -n "$UPSTREAM_VERSION" ] || {
  echo "Could not read upstream version from module_data/module.prop" >&2
  exit 1
}
UPSTREAM_VERSION_CODE=$(sed -n 's/^versionCode=//p' module_data/module.prop | head -n1)
[ -n "$UPSTREAM_VERSION_CODE" ] || {
  echo "Could not read upstream versionCode from module_data/module.prop" >&2
  exit 1
}
if [ -n "$OVERRIDE_VERSION" ]; then
  NEW_VERSION="$OVERRIDE_VERSION"
  NEW_VERSION_CODE=$((UPSTREAM_VERSION_CODE + 1))
else
  NEW_VERSION=$(bump_minor_version "$UPSTREAM_VERSION")
  NEW_VERSION_CODE=$((UPSTREAM_VERSION_CODE + 1))
fi
case "$NEW_VERSION" in
  v*) ;;
  *) NEW_VERSION="v$NEW_VERSION" ;;
esac

echo "==> Upstream version: $UPSTREAM_VERSION ($UPSTREAM_VERSION_CODE)"
echo "==> New module version: $NEW_VERSION ($NEW_VERSION_CODE)"

echo "==> Updating module metadata"
sed -i "s/^version=.*/version=$NEW_VERSION/" module_data/module.prop
sed -i "s/^versionCode=.*/versionCode=$NEW_VERSION_CODE/" module_data/module.prop

echo "==> Updating OpenSSL/OpenSSH versions"
sed -i "s/^OPENSSL?=.*/OPENSSL?=$OPENSSL_VER/" openssl.mk
sed -i "s/^OPENSSH?=.*/OPENSSH?=$OPENSSH_VER/" openssh.mk
LIBCRYPTO_VERSION=$(openssl_libcrypto_version "$OPENSSL_VER")
sed -i "s/^LIBCRYPTO_VERSION:=.*/LIBCRYPTO_VERSION:=$LIBCRYPTO_VERSION/" openssl.mk
sed -i 's|^DOWNLOAD_URL:=.*|DOWNLOAD_URL:=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/$(ARCHIVE_NAME)|' openssh.mk
echo "==> Applying production hardening flags"
# apply_hardening_flags "$HARDENED_CFLAGS" "$HARDENED_LDFLAGS"

echo "==> Adjusting OpenSSH configure flags"
sed -i 's|CPPFLAGS="$(CFLAGS) -DHAVE_ATTRIBUTE__SENTINEL__=1 -DHAVE__RES_EXTERN=1"|CPPFLAGS="$(CFLAGS) -DHAVE_ATTRIBUTE__SENTINEL__=1 -DHAVE__RES_EXTERN=1 -DHAVE_MBLEN=1 -Wno-deprecated-declarations -Wno-error=incompatible-function-pointer-types -Wno-incompatible-function-pointer-types"|' openssh.mk

echo "==> Fixing opensshd.init path generation"
sed -i "s|'s#=/bin#=/system/bin#'|'s#=/bin#=/system/bin#' -e 's#=/usr/bin#=/system/bin#'|" magisk_module.mk

if [ -n "$TARGET_ARCH" ]; then
  echo "==> Limiting module package to architecture: $TARGET_ARCH"
  limit_magisk_module_to_arch "$TARGET_ARCH"
fi

echo "==> Downloading source archives"
mkdir -p dl checksums patches "$WORK_ROOT/patch-work"
download_source_archive "$OPENSSL_VER" "https://www.openssl.org/source/${OPENSSL_VER}.tar.gz"
download_source_archive "$OPENSSH_VER" "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${OPENSSH_VER}.tar.gz"

prepare_openssh_patch "$WORK_ROOT/patch-work" "$PWD/dl/${OPENSSH_VER}.tar.gz"

echo "==> Building module"
export ANDROID_ROOT

JOBS="-j$(getconf _NPROCESSORS_ONLN)"

if [ -n "$TARGET_ARCH" ]; then
  echo "==> Building for architecture: $TARGET_ARCH"
  make -f all_arches.mk $JOBS "all_$TARGET_ARCH"
  echo "==> Creating flashable zip"
  make -f all_arches.mk $JOBS zip
else
  echo "==> Building for all architectures"
  make -f all_arches.mk $JOBS zip
fi

echo "==> Locating build output"
BUILT_ZIP=$(find . -maxdepth 1 -name "magisk_ssh_*.zip" -type f 2>/dev/null | sort | tail -n1 || true)

if [ -z "$BUILT_ZIP" ] || [ ! -f "$BUILT_ZIP" ]; then
  echo "Build completed but no zip found" >&2
  exit 1
fi

OUTPUT_ZIP="$SCRIPT_DIR/magisk_ssh-${NEW_VERSION}-magisk.zip"
echo "==> Copying zip to $OUTPUT_ZIP"
cp -f "$BUILT_ZIP" "$OUTPUT_ZIP"

echo "==> Output created: $OUTPUT_ZIP"
echo "==> Build cleanup of temporary work directory..."
