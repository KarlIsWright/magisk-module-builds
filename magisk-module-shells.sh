#!/usr/bin/env bash

# This script requires bash (do not run with `sh`).
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: This script must be run with bash." >&2
  echo "       Example: bash magisk-shells-update.sh [args...]" >&2
  exit 1
fi

set -euo pipefail

# NOTE: Many upstream build systems (notably ncurses) break when build paths contain spaces.
# By default ROOT_DIR is the current working directory; set ROOT_DIR explicitly if you want a different workspace.

# Defaults (may be overridden by env vars or CLI flags)
ROOT_DIR_DEFAULT="$PWD"
MODULE_DIR_DEFAULT="$PWD/magisk-shells"
ZIP_OUT_DEFAULT="$PWD/magisk-shells-v1.1-magisk.zip"
META_INF_SRC_DEFAULT=""

ROOT_DIR="${ROOT_DIR:-$ROOT_DIR_DEFAULT}"

# Derived dirs depend on ROOT_DIR, so only compute them *after* CLI parsing.
# If the user sets SRC_DIR/DEPS_DIR/STAGE_DIR via env var or CLI flag, those are respected.
SRC_DIR="${SRC_DIR:-}"
DEPS_DIR="${DEPS_DIR:-}"
STAGE_DIR="${STAGE_DIR:-}"

MODULE_DIR="${MODULE_DIR:-$MODULE_DIR_DEFAULT}"
ZIP_OUT="${ZIP_OUT:-$ZIP_OUT_DEFAULT}"
META_INF_SRC="${META_INF_SRC:-$META_INF_SRC_DEFAULT}"
CLEANUP="${CLEANUP:-0}"
SHELLS_README_URL_DEFAULT="${SHELLS_README_URL_DEFAULT:-https://raw.githubusercontent.com/KarlIsWright/magisk-module-builds/refs/heads/main/magisk-module-shells-README.md}"
SHELLS_README_URL="${SHELLS_README_URL:-$SHELLS_README_URL_DEFAULT}"

# Android SDK/NDK detection (override with --ndk/--api or NDK/API env vars)
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/.android/Sdk}}"

find_latest_ndk() {
  local ndk_dir
  for ndk_dir in "$ANDROID_SDK_ROOT/ndk" "$ANDROID_SDK_ROOT/ndk-bundle"; do
    if [ -d "$ndk_dir" ]; then
      if [ -d "$ndk_dir/toolchains" ]; then
        # ndk-bundle style
        echo "$ndk_dir"
        return 0
      fi
      # side-by-side ndk versions
      local latest
      latest=$(ls -1 "$ndk_dir" 2>/dev/null | sort -V | tail -n 1 || true)
      if [ -n "$latest" ] && [ -d "$ndk_dir/$latest/toolchains" ]; then
        echo "$ndk_dir/$latest"
        return 0
      fi
    fi
  done
  return 1
}

find_highest_api() {
  local platforms_dir="$ANDROID_SDK_ROOT/platforms"
  if [ -d "$platforms_dir" ]; then
    ls -1 "$platforms_dir" 2>/dev/null \
      | sed -n 's/^android-\([0-9][0-9]*\)$/\1/p' \
      | sort -n \
      | tail -n 1 \
      || true
  fi
}

find_highest_ndk_api() {
  local tool_bin="$1"
  # clang wrappers are named like: aarch64-linux-android21-clang
  ls -1 "$tool_bin"/aarch64-linux-android*-clang 2>/dev/null \
    | sed -n 's/.*aarch64-linux-android\([0-9][0-9]*\)-clang$/\1/p' \
    | sort -n \
    | tail -n 1 \
    || true
}

NDK_DEFAULT=""
if NDK_DEFAULT=$(find_latest_ndk); then
  :
else
  NDK_DEFAULT="$ANDROID_SDK_ROOT/ndk"
fi

# NDK is safe to select early; API default should be chosen later once NDK/TOOL are known.
NDK="${NDK:-$NDK_DEFAULT}"
API="${API:-}"

BASH_REPO="${BASH_REPO:-https://git.savannah.gnu.org/git/bash.git}"
ZSH_REPO="${ZSH_REPO:-https://git.code.sf.net/p/zsh/code}"
FISH_REPO="${FISH_REPO:-https://github.com/fish-shell/fish-shell.git}"
NCURSES_REPO="${NCURSES_REPO:-https://github.com/mirror/ncurses.git}"

# Extras bundled into the Magisk module
STARSHIP_TARBALL_URL="${STARSHIP_TARBALL_URL:-https://github.com/starship/starship/releases/latest/download/starship-aarch64-unknown-linux-musl.tar.gz}"
OHMYZSH_REPO="${OHMYZSH_REPO:-https://github.com/ohmyzsh/ohmyzsh.git}"
OHMYZSH_REF="${OHMYZSH_REF:-master}"

# Git refs (branch/tag/commit). Defaults to the tip of the default branch.
REF_DEFAULT="${REF_DEFAULT:-origin/HEAD}"
BASH_REF="${BASH_REF:-$REF_DEFAULT}"
ZSH_REF="${ZSH_REF:-$REF_DEFAULT}"
FISH_REF="${FISH_REF:-$REF_DEFAULT}"
NCURSES_REF="${NCURSES_REF:-$REF_DEFAULT}"

# Which shells to build. Accepts:
#   all
#   bash
#   zsh
#   fish
#   or any combination (space- or comma-separated), e.g. "bash,zsh" or "bash fish".
# BUILD_SHELL is accepted as an alias.
BUILD_SHELLS_RAW="${BUILD_SHELLS:-${BUILD_SHELL:-all}}"

usage() {
  cat <<'EOF'
Usage: magisk-shells-update.sh [options]
Options (all may also be set via environment variables):
  --root_dir=PATH
  --src_dir=PATH
  --deps_dir=PATH
  --stage_dir=PATH
  --module_dir=PATH
      Output directory for the Magisk module contents (e.g. /path/to/magisk-shells).
      WARNING: do not set this to your home directory or /.
  --zip_out=PATH
  --meta_inf_src=PATH        (optional; if not set, META-INF is generated)
  --readme-url=URL           (optional; remote README for module package, best-effort)
  --cleanup                  remove magisk-shells-build and magisk-shells dirs after successful zip
  --ndk=PATH
  --api=LEVEL
  --build-shells=LIST        all|bash|zsh|fish or comma/space-separated combinations
  --ref_default=REF          default git ref (e.g. origin/HEAD, tag, sha)
  --bash_ref=REF
  --zsh_ref=REF
  --fish_ref=REF
  --ncurses_ref=REF
  --bash_repo=URL
  --zsh_repo=URL
  --fish_repo=URL
  --ncurses_repo=URL
  -h, --help
EOF
}

# Parse CLI flags (supports --key=value and --key value)
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;

    --root_dir=*) ROOT_DIR="${1#*=}" ;;
    --root_dir) shift; ROOT_DIR="$1" ;;

    --src_dir=*) SRC_DIR="${1#*=}" ;;
    --src_dir) shift; SRC_DIR="$1" ;;

    --deps_dir=*) DEPS_DIR="${1#*=}" ;;
    --deps_dir) shift; DEPS_DIR="$1" ;;

    --stage_dir=*) STAGE_DIR="${1#*=}" ;;
    --stage_dir) shift; STAGE_DIR="$1" ;;

    --module_dir=*) MODULE_DIR="${1#*=}" ;;
    --module_dir) shift; MODULE_DIR="$1" ;;

    --zip_out=*) ZIP_OUT="${1#*=}" ;;
    --zip_out) shift; ZIP_OUT="$1" ;;

    --meta_inf_src=*) META_INF_SRC="${1#*=}" ;;
    --meta_inf_src) shift; META_INF_SRC="$1" ;;
    --readme-url=*) SHELLS_README_URL="${1#*=}" ;;
    --readme-url) shift; SHELLS_README_URL="$1" ;;

    --cleanup) CLEANUP=1 ;;

    --ndk=*) NDK="${1#*=}" ;;
    --ndk) shift; NDK="$1" ;;

    --api=*) API="${1#*=}" ;;
    --api) shift; API="$1" ;;

    --build-shells=*) BUILD_SHELLS_RAW="${1#*=}" ;;
    --build-shells) shift; BUILD_SHELLS_RAW="$1" ;;

    --ref_default=*) REF_DEFAULT="${1#*=}" ;;
    --ref_default) shift; REF_DEFAULT="$1" ;;

    --bash_ref=*) BASH_REF="${1#*=}" ;;
    --bash_ref) shift; BASH_REF="$1" ;;
    --zsh_ref=*) ZSH_REF="${1#*=}" ;;
    --zsh_ref) shift; ZSH_REF="$1" ;;
    --fish_ref=*) FISH_REF="${1#*=}" ;;
    --fish_ref) shift; FISH_REF="$1" ;;
    --ncurses_ref=*) NCURSES_REF="${1#*=}" ;;
    --ncurses_ref) shift; NCURSES_REF="$1" ;;

    --bash_repo=*) BASH_REPO="${1#*=}" ;;
    --bash_repo) shift; BASH_REPO="$1" ;;
    --zsh_repo=*) ZSH_REPO="${1#*=}" ;;
    --zsh_repo) shift; ZSH_REPO="$1" ;;
    --fish_repo=*) FISH_REPO="${1#*=}" ;;
    --fish_repo) shift; FISH_REPO="$1" ;;
    --ncurses_repo=*) NCURSES_REPO="${1#*=}" ;;
    --ncurses_repo) shift; NCURSES_REPO="$1" ;;

    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# Compute derived dirs now that ROOT_DIR is finalized (post-CLI parsing).
SRC_DIR="${SRC_DIR:-$ROOT_DIR/magisk-shells-build/src}"
DEPS_DIR="${DEPS_DIR:-$ROOT_DIR/magisk-shells-build/deps}"
STAGE_DIR="${STAGE_DIR:-$ROOT_DIR/magisk-shells-build/stage}"

TOOL="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

if [ ! -d "$NDK" ]; then
  echo "ERROR: NDK path not found: $NDK" >&2
  echo "       Set ANDROID_SDK_ROOT/ANDROID_HOME or pass --ndk=/path/to/ndk" >&2
  exit 1
fi

if [ ! -d "$TOOL" ]; then
  echo "ERROR: NDK toolchain bin dir not found: $TOOL" >&2
  echo "       (This script currently expects the linux-x86_64 prebuilt toolchain.)" >&2
  exit 1
fi

# If API wasn't specified, pick the highest API level that the selected NDK can actually target.
if [ -z "${API}" ]; then
  API_PLATFORM="$(find_highest_api || true)"
  API_NDK_MAX="$(find_highest_ndk_api "$TOOL" || true)"

  if [ -n "$API_PLATFORM" ] && [ -n "$API_NDK_MAX" ]; then
    # Choose the lower of (highest installed platform, highest supported by NDK wrappers)
    if [ "$API_PLATFORM" -le "$API_NDK_MAX" ]; then
      API="$API_PLATFORM"
    else
      API="$API_NDK_MAX"
    fi
  elif [ -n "$API_NDK_MAX" ]; then
    API="$API_NDK_MAX"
  elif [ -n "$API_PLATFORM" ]; then
    API="$API_PLATFORM"
  else
    API=28
  fi
fi

case "$API" in
  ''|*[!0-9]*)
    echo "ERROR: API must be a numeric Android API level (e.g. 28, 34). Got: $API" >&2
    exit 1
    ;;
  *) : ;;
esac

# Re-apply per-repo refs if they were still inheriting the previous REF_DEFAULT.
BASH_REF="${BASH_REF:-$REF_DEFAULT}"
ZSH_REF="${ZSH_REF:-$REF_DEFAULT}"
FISH_REF="${FISH_REF:-$REF_DEFAULT}"
NCURSES_REF="${NCURSES_REF:-$REF_DEFAULT}"

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

ensure_cmd git
ensure_cmd make
ensure_cmd cmake
ensure_cmd curl
ensure_cmd rustup
ensure_cmd python3
ensure_cmd zip
ensure_cmd autoconf
ensure_cmd autoheader
fetch_module_readme_best_effort() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.tmp.$$"

  if curl -fsSL "$url" -o "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$dest"
    echo "Applied remote README: $url"
    return 0
  fi

  rm -f "$tmp" 2>/dev/null || true
  echo "WARNING: failed to fetch remote README (or empty response); keeping existing module README"
}

# Safety: refuse to operate on obviously dangerous output dirs.
canon_path() {
  python3 - "$1" <<'PY'
import os, sys
p = sys.argv[1]
print(os.path.realpath(p))
PY
}

ROOT_DIR_CANON=$(canon_path "$ROOT_DIR")
MODULE_DIR_CANON=$(canon_path "$MODULE_DIR")
HOME_CANON=$(canon_path "$HOME")

case "$MODULE_DIR_CANON" in
  "/"|"$HOME_CANON")
    echo "ERROR: --module_dir points to an unsafe path: $MODULE_DIR_CANON" >&2
    echo "       Use something like: --module_dir=$HOME_CANON/magisk-shells" >&2
    exit 1
    ;;
esac

for d in "$ROOT_DIR" "$SRC_DIR" "$DEPS_DIR" "$STAGE_DIR"; do
  case "$d" in
    *" "*)
      echo "ERROR: build dir contains spaces: $d" >&2
      echo "Set ROOT_DIR/SRC_DIR/DEPS_DIR/STAGE_DIR to a path without spaces." >&2
      exit 1
      ;;
  esac
done

mkdir -p "$SRC_DIR" "$DEPS_DIR" "$STAGE_DIR"

# Resolve BUILD_SHELLS selection
WANT_BASH=0
WANT_ZSH=0
WANT_FISH=0
case "${BUILD_SHELLS_RAW}" in
  all|ALL|"" )
    WANT_BASH=1
    WANT_ZSH=1
    WANT_FISH=1
    ;;
  *)
    BUILD_SHELLS_CANON=$(echo "$BUILD_SHELLS_RAW" | tr ',' ' ')
    for s in $BUILD_SHELLS_CANON; do
      case "$s" in
        bash) WANT_BASH=1 ;;
        zsh) WANT_ZSH=1 ;;
        fish) WANT_FISH=1 ;;
        *)
          echo "ERROR: unknown shell in BUILD_SHELLS: $s" >&2
          exit 1
          ;;
      esac
    done
    ;;
esac

if [ "$WANT_ZSH" -eq 1 ]; then
  WANT_NCURSES=1
else
  WANT_NCURSES=0
fi

sync_repo() {
  local name="$1"
  local url="$2"
  local ref="$3"
  local dir="$SRC_DIR/$name"

  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --all --tags --prune
  else
    if [ "$name" = "bash" ]; then
      # Savannah asks users to shallow clone to reduce load.
      git clone --depth 1 --no-single-branch "$url" "$dir"
    else
      # Keep clones reasonably small but with enough history for common tag pins.
      git clone --depth 289 --no-single-branch "$url" "$dir"
    fi
    git -C "$dir" fetch --all --tags --prune
  fi

  git -C "$dir" checkout -f --detach "$ref"
  git -C "$dir" reset --hard "$ref"
}

if [ "$WANT_BASH" -eq 1 ]; then
  sync_repo bash "$BASH_REPO" "$BASH_REF"
fi
if [ "$WANT_ZSH" -eq 1 ]; then
  sync_repo zsh "$ZSH_REPO" "$ZSH_REF"
fi
if [ "$WANT_FISH" -eq 1 ]; then
  sync_repo fish "$FISH_REPO" "$FISH_REF"
fi
if [ "$WANT_NCURSES" -eq 1 ]; then
  sync_repo ncurses "$NCURSES_REPO" "$NCURSES_REF"
fi

export CC="$TOOL/aarch64-linux-android${API}-clang"
export CXX="$TOOL/aarch64-linux-android${API}-clang++"
export AR="$TOOL/llvm-ar"
export RANLIB="$TOOL/llvm-ranlib"
export STRIP="$TOOL/llvm-strip"

COMMON_CFLAGS="-O2 -std=gnu11 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -fPIC -ffunction-sections -fdata-sections"
COMMON_LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,--gc-sections"

echo "[1/6] Build bash"
if [ "$WANT_BASH" -eq 1 ]; then
  BASHANSI_H="$SRC_DIR/bash/bashansi.h" python3 - <<'PY'
import os
from pathlib import Path
path = Path(os.environ["BASHANSI_H"])
text = path.read_text()
old = """#  else
#    undef bool
typedef unsigned char bool;
#    define true 1
#    define false 0
#  endif
#endif
"""
new = """#  else
#    if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#      include <stdbool.h>
#    else
#      undef bool
typedef unsigned char bool;
#      define true 1
#      define false 0
#    endif
#  endif
#endif
"""
if old in text:
    text = text.replace(old, new)
    path.write_text(text)
PY
  (cd "$SRC_DIR/bash" && make distclean >/dev/null 2>&1 || true)
  (cd "$SRC_DIR/bash" && CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
    ./configure --host=aarch64-linux-android --prefix=/system --disable-nls --without-bash-malloc --disable-rpath \
    CC_FOR_BUILD=gcc HOSTCC=gcc)
  (cd "$SRC_DIR/bash" && make -j"$(nproc)")
fi

echo "[2/6] Build ncurses (static)"
NCURSES_PREFIX="$DEPS_DIR/ncurses"
if [ "$WANT_NCURSES" -eq 1 ]; then
  (cd "$SRC_DIR/ncurses" && make distclean >/dev/null 2>&1 || true)
  (cd "$SRC_DIR/ncurses" && CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
    ./configure --host=aarch64-linux-android --prefix="$NCURSES_PREFIX" \
    --without-ada --without-tests --without-debug --enable-static --disable-shared --enable-widec \
    --with-termlib --with-default-terminfo-dir=/system/etc/terminfo --with-terminfo-dirs=/system/etc/terminfo)
  (cd "$SRC_DIR/ncurses" && make -j"$(nproc)")
  (cd "$SRC_DIR/ncurses" && make install.libs install.includes)
fi

echo "[3/6] Build zsh"
if [ "$WANT_ZSH" -eq 1 ]; then
  ZSH_CPPFLAGS="-I$NCURSES_PREFIX/include -I$NCURSES_PREFIX/include/ncursesw"
  ZSH_CFLAGS="$COMMON_CFLAGS -DHAVE_BOOLCODES=1"
  ZSH_LDFLAGS="-L$NCURSES_PREFIX/lib $COMMON_LDFLAGS"
  ZSH_LIBS="-lncursesw -ltinfow -lm"
  (cd "$SRC_DIR/zsh" && make distclean >/dev/null 2>&1 || true)
  # zsh git checkouts may not ship a pre-generated ./configure
  if [ ! -x "$SRC_DIR/zsh/configure" ]; then
    (cd "$SRC_DIR/zsh" && ./.preconfig)
  fi
  (cd "$SRC_DIR/zsh" && CPPFLAGS="$ZSH_CPPFLAGS" CFLAGS="$ZSH_CFLAGS" LDFLAGS="$ZSH_LDFLAGS" LIBS="$ZSH_LIBS" ./configure --host=aarch64-linux-android --prefix=/system)
  (cd "$SRC_DIR/zsh" && make -j"$(nproc)" \
    CPPFLAGS="$ZSH_CPPFLAGS" CFLAGS="$ZSH_CFLAGS" LDFLAGS="$ZSH_LDFLAGS" LIBS="$ZSH_LIBS" \
    ZSH_CURSES_H=curses.h ZSH_TERM_H=term.h)
fi

echo "[4/6] Build fish"
if [ "$WANT_FISH" -eq 1 ]; then
  FISH_ENV_RS="$SRC_DIR/fish/src/env/environment.rs" FISH_PATH_RS="$SRC_DIR/fish/src/path.rs" python3 - <<'PY'
import os
from pathlib import Path

env_path = Path(os.environ["FISH_ENV_RS"])
text = env_path.read_text()

# Patch FALLBACK_PATH on Android: libc::confstr / libc::_CS_PATH may not exist in libc for Android.
start = text.find("pub(crate) static FALLBACK_PATH")
end = text.find("});", start)
if start != -1 and end != -1:
    block = text[start:end+3]
    needs_android_guard = ("libc::confstr" in block or "libc::_CS_PATH" in block) and ("target_os = \"android\"" not in block)
    if needs_android_guard:
        replacement = """pub(crate) static FALLBACK_PATH: LazyLock<&[WString]> = LazyLock::new(|| {
    let paths: Vec<WString> = {
        cfg_if::cfg_if! {
            if #[cfg(target_os = \"android\")] {
                vec![
                    str2wcstring(PREFIX) + L!(\"/bin\"),
                    L!(\"/usr/bin\").to_owned(),
                    L!(\"/bin\").to_owned(),
                ]
            } else {
                // _CS_PATH: colon-separated paths to find POSIX utilities. Same as USER_CS_PATH.
                // Fix until rust-lang/libc#4956 is merged
                cfg_if::cfg_if!(
                    if #[cfg(target_os = \"illumos\")] {
                        // See https://github.com/illumos/illumos-gate/blob/af641d205ecf080be0d900f89c4f3d2adb84f33f/usr/src/uts/common/sys/unistd.h#L50
                        let cs_path: c_int = 65;
                    } else {
                        let cs_path = libc::_CS_PATH;
                    }
                );

                let buf_size = unsafe { libc::confstr(cs_path, std::ptr::null_mut(), 0) };
                if buf_size > 0 {
                    let mut buf = vec![b'\\0' as libc::c_char; buf_size];
                    unsafe { libc::confstr(cs_path, buf.as_mut_ptr(), buf_size) };
                    let buf = buf;
                    // safety: buf should contain a null-byte, and is not mutable unless we move ownership
                    let cstr = unsafe { CStr::from_ptr(buf.as_ptr()) };
                    colon_split(&[cstr2wcstring(cstr)])
                } else {
                    vec![
                        str2wcstring(PREFIX) + L!(\"/bin\"),
                        L!(\"/usr/bin\").to_owned(),
                        L!(\"/bin\").to_owned(),
                    ]
                }
            }
        }
    };
    Box::leak(paths.into_boxed_slice())
});
"""
        text = text[:start] + replacement + text[end+3:]
        env_path.write_text(text)

path_path = Path(os.environ["FISH_PATH_RS"])
text = path_path.read_text()
old = """                } else {
                    let mut buf = MaybeUninit::uninit();
                    if unsafe { libc::statfs(narrow.as_ptr(), buf.as_mut_ptr()) } < 0 {
                        return DirRemoteness::Unknown;
                    }
                    let buf = unsafe { buf.assume_init() };
                    // statfs::f_flags types differ.
                    #[allow(clippy::useless_conversion)]
                    let flags = buf.f_flags as u64;
                    #[allow(clippy::unnecessary_cast)]
                    if flags & (libc::MNT_LOCAL as u64) != 0 {
                        DirRemoteness::Local
                    } else {
                        DirRemoteness::Remote
                    }
                }
"""
new = """                } else if #[cfg(target_os = "android")] {
                    DirRemoteness::Unknown
                } else {
                    let mut buf = MaybeUninit::uninit();
                    if unsafe { libc::statfs(narrow.as_ptr(), buf.as_mut_ptr()) } < 0 {
                        return DirRemoteness::Unknown;
                    }
                    let buf = unsafe { buf.assume_init() };
                    // statfs::f_flags types differ.
                    #[allow(clippy::useless_conversion)]
                    let flags = buf.f_flags as u64;
                    #[allow(clippy::unnecessary_cast)]
                    if flags & (libc::MNT_LOCAL as u64) != 0 {
                        DirRemoteness::Local
                    } else {
                        DirRemoteness::Remote
                    }
                }
"""
if old in text:
    path_path.write_text(text.replace(old, new))
PY
  rustup update stable
  rustup default stable
  rustup target add aarch64-linux-android --toolchain stable
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOL/aarch64-linux-android${API}-clang"
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$TOOL/llvm-ar"
  export RUSTFLAGS="-C link-arg=-Wl,-z,relro -C link-arg=-Wl,-z,now -C link-arg=-Wl,-z,noexecstack -C link-arg=-Wl,--gc-sections"
  export FISH_BUILD_DOCS=0
  (cd "$SRC_DIR/fish" && rustup run stable cargo build --release --target aarch64-linux-android)
fi

echo "[5/6] Stage binaries"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/extras" "$STAGE_DIR/templates"
rm -f "$STAGE_DIR/bin/bash" "$STAGE_DIR/bin/zsh" "$STAGE_DIR/bin/fish" "$STAGE_DIR/bin/starship" 2>/dev/null || true
if [ "$WANT_BASH" -eq 1 ]; then
  cp -f "$SRC_DIR/bash/bash" "$STAGE_DIR/bin/"
fi
if [ "$WANT_ZSH" -eq 1 ]; then
  cp -f "$SRC_DIR/zsh/Src/zsh" "$STAGE_DIR/bin/"
fi
if [ "$WANT_FISH" -eq 1 ]; then
  cp -f "$SRC_DIR/fish/target/aarch64-linux-android/release/fish" "$STAGE_DIR/bin/"
fi

# Starship prompt (optional; best-effort)
(
  tmp="$STAGE_DIR/extras/starship"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  curl -fsSL "$STARSHIP_TARBALL_URL" -o "$tmp/starship.tgz"
  tar -xzf "$tmp/starship.tgz" -C "$tmp"
  if [ -f "$tmp/starship" ]; then
    cp -f "$tmp/starship" "$STAGE_DIR/bin/starship"
  fi
) >/dev/null 2>&1 || true

chmod 755 "$STAGE_DIR/bin/"* 2>/dev/null || true

# Oh My Zsh (optional; best-effort)
(
  ohdir="$STAGE_DIR/extras/oh-my-zsh"
  rm -rf "$ohdir"
  git clone --depth 1 "$OHMYZSH_REPO" "$ohdir"
  (cd "$ohdir" && git checkout -f "$OHMYZSH_REF")
) >/dev/null 2>&1 || true

# Template dotfiles (non-destructive install)
cat > "$STAGE_DIR/templates/zshrc" <<'EOF'
# Magisk Shells template ~/.zshrc
# If you already have your own config, do not use this.

# Load Oh My Zsh if present
if [ -d "$HOME/.oh-my-zsh" ]; then
  export ZSH="$HOME/.oh-my-zsh"
  ZSH_THEME="robbyrussell"
  plugins=(git)
  source "$ZSH/oh-my-zsh.sh"
fi

# Starship prompt if installed
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
EOF

cat > "$STAGE_DIR/templates/bashrc" <<'EOF'
# Magisk Shells template ~/.bashrc
# If you already have your own config, do not use this.

# Starship prompt if installed
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi
EOF

cat > "$STAGE_DIR/templates/config_fish" <<'EOF'
# Magisk Shells template config.fish
# If you already have your own config, do not use this.

if type -q starship
  starship init fish | source
end
EOF

echo "[6/6] Build Magisk module"

# Extra safety: never delete HOME or / even if passed via --module_dir.
if [ "$MODULE_DIR_CANON" = "$HOME_CANON" ] || [ "$MODULE_DIR_CANON" = "/" ]; then
  echo "ERROR: refusing to remove unsafe MODULE_DIR: $MODULE_DIR_CANON" >&2
  exit 1
fi

rm -rf "$MODULE_DIR"
mkdir -p "$MODULE_DIR/arch/arm64/bin" "$MODULE_DIR/common" "$MODULE_DIR/common/templates" "$MODULE_DIR/common/oh-my-zsh"

# META-INF: either copy from META_INF_SRC (if provided) or generate a fresh one.
if [ -n "$META_INF_SRC" ]; then
  cp -a "$META_INF_SRC" "$MODULE_DIR/"
else
  mkdir -p "$MODULE_DIR/META-INF/com/google/android"

  # updater-script: no-op (Magisk update-binary handles install).
  cat > "$MODULE_DIR/META-INF/com/google/android/updater-script" <<'EOF'
#MAGISK
EOF

  # update-binary: standard Magisk module installer entrypoint.
  cat > "$MODULE_DIR/META-INF/com/google/android/update-binary" <<'EOF'
#!/sbin/sh

# Magisk module update-binary
# This is executed by Magisk's installer.

OUTFD=$2
ZIPFILE=$3

ui_print() {
  echo -e "ui_print $1\nui_print" > /proc/self/fd/$OUTFD
}

ui_print "- Installing Magisk module"

# Find Magisk's util_functions.sh
UTIL=""
for p in \
  /data/adb/magisk/util_functions.sh \
  /data/adb/magisk/magiskboot \
  /data/adb/magisk/busybox \
  /data/adb/magisk/magiskpolicy \
  /data/adb/magisk/magiskinit; do
  :
done

if [ -f /data/adb/magisk/util_functions.sh ]; then
  UTIL=/data/adb/magisk/util_functions.sh
elif [ -f /data/adb/modules_update/.magisk/util_functions.sh ]; then
  UTIL=/data/adb/modules_update/.magisk/util_functions.sh
elif [ -f /data/adb/modules/.magisk/util_functions.sh ]; then
  UTIL=/data/adb/modules/.magisk/util_functions.sh
fi

if [ -z "$UTIL" ]; then
  ui_print "! Cannot find util_functions.sh"
  exit 1
fi

. "$UTIL"

install_module
exit 0
EOF

  chmod 755 "$MODULE_DIR/META-INF/com/google/android/update-binary"
fi

cp -f "$STAGE_DIR/bin/"* "$MODULE_DIR/arch/arm64/bin/" 2>/dev/null || true

# Bundle extras (if available)
if [ -d "$STAGE_DIR/extras/oh-my-zsh" ]; then
  cp -a "$STAGE_DIR/extras/oh-my-zsh/." "$MODULE_DIR/common/oh-my-zsh/" 2>/dev/null || true
fi

cp -f "$STAGE_DIR/templates/zshrc" "$MODULE_DIR/common/templates/.zshrc" 2>/dev/null || true
cp -f "$STAGE_DIR/templates/bashrc" "$MODULE_DIR/common/templates/.bashrc" 2>/dev/null || true
cp -f "$STAGE_DIR/templates/config_fish" "$MODULE_DIR/common/templates/config.fish" 2>/dev/null || true

cat > "$MODULE_DIR/module.prop" <<'EOF'
id=magisk-shells
name=Magisk Shells
version=v1.1
versionCode=110
author=kwright
description=bash + zsh + fish + starship prompt (+ optional Oh My Zsh templates). Binaries in /system/bin, templates in /data/adb/magisk_shells
minMagisk=24000
EOF

cat > "$MODULE_DIR/install.sh" <<'EOF'
##########################################################################################
#
# Magisk Module Installer Script
#
##########################################################################################

SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

REPLACE="
"

print_modname() {
  ui_print "*******************************"
  ui_print "        Magisk Shells          "
  ui_print "*******************************"
}

on_install() {
  local TMPDIR="$MODPATH/tmp"
  if [ "$ARCH" != "arm64" ]; then
    abort "Unsupported architecture: $ARCH (this build currently ships arm64 binaries only)"
  fi
  ui_print "[0/4] Preparing module directory"
  mkdir -p "$TMPDIR"
  mkdir -p "$MODPATH/system/bin"

  ui_print "[1/4] Extracting shells for $ARCH"
  unzip -o "$ZIPFILE" "arch/$ARCH/bin/*" -d "$TMPDIR" >&2

  if [ -f "$TMPDIR/arch/$ARCH/bin/bash" ]; then
    mv "$TMPDIR/arch/$ARCH/bin/bash" "$MODPATH/system/bin/"
    mkdir -p /data/adb/magisk_shells/bash
  fi
  if [ -f "$TMPDIR/arch/$ARCH/bin/zsh" ]; then
    mv "$TMPDIR/arch/$ARCH/bin/zsh" "$MODPATH/system/bin/"
    mkdir -p /data/adb/magisk_shells/zsh
  fi
  if [ -f "$TMPDIR/arch/$ARCH/bin/fish" ]; then
    mv "$TMPDIR/arch/$ARCH/bin/fish" "$MODPATH/system/bin/"
    mkdir -p /data/adb/magisk_shells/fish
  fi
  if [ -f "$TMPDIR/arch/$ARCH/bin/starship" ]; then
    mv "$TMPDIR/arch/$ARCH/bin/starship" "$MODPATH/system/bin/"
  fi

  # Bundle Oh My Zsh to persistent storage for users that have a writable $HOME.
  if [ -d "$MODPATH/common/oh-my-zsh" ] && [ ! -d /data/adb/magisk_shells/oh-my-zsh ]; then
    mkdir -p /data/adb/magisk_shells/oh-my-zsh
    cp -a "$MODPATH/common/oh-my-zsh/." /data/adb/magisk_shells/oh-my-zsh/ 2>/dev/null || true
  fi

  # Optionally install template dotfiles if $HOME looks safe/writable.
  # We do NOT override existing files.
  if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then
    if [ -f "$MODPATH/common/templates/.bashrc" ] && [ ! -e "$HOME/.bashrc" ]; then
      cp -f "$MODPATH/common/templates/.bashrc" "$HOME/.bashrc" || true
    fi
    if [ -f "$MODPATH/common/templates/.zshrc" ] && [ ! -e "$HOME/.zshrc" ]; then
      cp -f "$MODPATH/common/templates/.zshrc" "$HOME/.zshrc" || true
    fi
    # fish config via XDG; only attempt if XDG_CONFIG_HOME is set to a writable dir.
    if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -d "$XDG_CONFIG_HOME" ] && [ -w "$XDG_CONFIG_HOME" ]; then
      mkdir -p "$XDG_CONFIG_HOME/fish" 2>/dev/null || true
      if [ -f "$MODPATH/common/templates/config.fish" ] && [ ! -e "$XDG_CONFIG_HOME/fish/config.fish" ]; then
        cp -f "$MODPATH/common/templates/config.fish" "$XDG_CONFIG_HOME/fish/config.fish" || true
      fi
    fi
  fi

  ui_print "[2/4] Creating config directories"
  mkdir -p /data/adb/magisk_shells

  ui_print "[3/4] Creating README"
  if [ ! -f /data/adb/magisk_shells/README ]; then
    cat > /data/adb/magisk_shells/README <<'EOFX'
Magisk Shells module

Installed shells:
  /system/bin/bash
  /system/bin/zsh
  /system/bin/fish

Suggested config locations:
  Bash: /data/adb/magisk_shells/bash
  Zsh:  /data/adb/magisk_shells/zsh  (set ZDOTDIR if desired)
  Fish: /data/adb/magisk_shells/fish (set XDG_CONFIG_HOME if desired)

This module does not set environment variables automatically.
EOFX
  fi

  ui_print "[4/4] Cleaning up"
  rm -rf "$TMPDIR"
}

set_permissions() {
  set_perm_recursive $MODPATH 0 0 0755 0644
  set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
  set_perm_recursive /data/adb/magisk_shells 0 0 0755 0644
}
EOF

cat > "$MODULE_DIR/uninstall.sh" <<'EOF'
if ! test -e /data/adb/magisk_shells/KEEP_ON_UNINSTALL ; then
    rm -rf /data/adb/magisk_shells
fi
EOF

# Helper to apply templates into a user-provided writable $HOME / $ZDOTDIR.
mkdir -p "$MODULE_DIR/system/bin"
cat > "$MODULE_DIR/system/bin/magisk-shells-init" <<'EOF'
#!/system/bin/sh

MODDIR=${0%/*}
# When installed, this script lives at /system/bin. The module files are mounted at runtime.
# We locate module dir via magisk module path.
MODPATH=""
for p in /data/adb/modules/magisk-shells /data/adb/modules_update/magisk-shells; do
  if [ -d "$p" ]; then MODPATH="$p"; break; fi
done

if [ -z "$MODPATH" ]; then
  echo "ERROR: cannot locate magisk-shells module dir" >&2
  exit 1
fi

if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
  echo "ERROR: HOME must be set to a writable directory (HOME=$HOME)" >&2
  echo "Example: HOME=/data/adb/magisk_shells magisk-shells-init" >&2
  exit 1
fi

# Copy Oh My Zsh to $HOME if user wants it there.
if [ -d "$MODPATH/common/oh-my-zsh" ] && [ ! -d "$HOME/.oh-my-zsh" ]; then
  cp -a "$MODPATH/common/oh-my-zsh" "$HOME/.oh-my-zsh" 2>/dev/null || true
fi

# Install templates non-destructively.
if [ -f "$MODPATH/common/templates/.bashrc" ] && [ ! -e "$HOME/.bashrc" ]; then
  cp -f "$MODPATH/common/templates/.bashrc" "$HOME/.bashrc" || true
fi

ZDOTDIR_REAL="${ZDOTDIR:-$HOME}"
if [ -d "$ZDOTDIR_REAL" ] && [ -w "$ZDOTDIR_REAL" ]; then
  if [ -f "$MODPATH/common/templates/.zshrc" ] && [ ! -e "$ZDOTDIR_REAL/.zshrc" ]; then
    cp -f "$MODPATH/common/templates/.zshrc" "$ZDOTDIR_REAL/.zshrc" || true
  fi
fi

XDG_CONFIG_HOME_REAL="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$XDG_CONFIG_HOME_REAL/fish" 2>/dev/null || true
if [ -d "$XDG_CONFIG_HOME_REAL" ] && [ -w "$XDG_CONFIG_HOME_REAL" ]; then
  if [ -f "$MODPATH/common/templates/config.fish" ] && [ ! -e "$XDG_CONFIG_HOME_REAL/fish/config.fish" ]; then
    cp -f "$MODPATH/common/templates/config.fish" "$XDG_CONFIG_HOME_REAL/fish/config.fish" || true
  fi
fi

echo "magisk-shells-init: done"
EOF

chmod 755 "$MODULE_DIR/system/bin/magisk-shells-init"

cat > "$MODULE_DIR/service.sh" <<'EOF'
#!/system/bin/sh

mkdir -p /data/adb/magisk_shells/bash
mkdir -p /data/adb/magisk_shells/zsh
mkdir -p /data/adb/magisk_shells/fish
EOF

chmod 755 "$MODULE_DIR/install.sh" "$MODULE_DIR/uninstall.sh" "$MODULE_DIR/service.sh"
fetch_module_readme_best_effort "$SHELLS_README_URL" "$MODULE_DIR/README.md"

(cd "$MODULE_DIR" && zip -r "$ZIP_OUT" .)

echo "Done: $ZIP_OUT"

if [ "$CLEANUP" -eq 1 ]; then
  # remove the build workspace and the module staging dir
  rm -rf "$ROOT_DIR/magisk-shells-build" "$MODULE_DIR"
fi
