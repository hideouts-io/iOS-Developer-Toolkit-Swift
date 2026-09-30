#!/bin/bash
# Builds the firmware helpers bundled with iOS Developer Toolkit (Swift): `idevicerestore` and
# `irecovery` from the libimobiledevice project, as universal (arm64 + x86_64) executables that
# link every third-party library statically and depend only on macOS system libraries.
#
#   scripts/build-restore-helpers.sh [OUTPUT_DIR]
#
# OUTPUT_DIR (default build-output/restore-helpers/out) receives:
#   bin/idevicerestore, bin/irecovery      universal executables
#   licenses/<project>/…                   each project's license and notices
#   SOURCES.txt                            the exact source of every component
#   STAMP                                  SHA-256 of this script, so a build is reused only
#                                          while the pinned sources and steps are unchanged
#
# Every source is pinned: git projects to a commit, OpenSSL to a release tarball and its published
# SHA-256. Needs Xcode, and autoconf, automake, libtool, pkg-config, and cmake (Homebrew). Builds
# happen under build-output/restore-helpers; nothing is installed on the system.
#
# The helpers are separate programs: the app runs them through CommandRunner and never links them.
# idevicerestore is LGPL-3.0; the libimobiledevice libraries are LGPL-2.1; libzip is BSD-3-Clause;
# OpenSSL is Apache-2.0.
set -euo pipefail

fail() { echo "build-restore-helpers: $*" >&2; exit 1; }
step() { echo "==> $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-output/restore-helpers"
OUT="${1:-$WORK/out}"
SRC="$WORK/src"
MIN_MACOS=14.0
JOBS="$(sysctl -n hw.ncpu)"

# name|git URL|commit|version label
GIT_SOURCES=(
  "libplist|https://github.com/libimobiledevice/libplist.git|32428abacb909988e8e960a8845a6430b17b6a60|2.7.0-git"
  "libimobiledevice-glue|https://github.com/libimobiledevice/libimobiledevice-glue.git|da770a7687f35fbb981db4d7b47b1b032cd5c2c7|1.3.2-git"
  "libusbmuxd|https://github.com/libimobiledevice/libusbmuxd.git|93eb168bf6b07472d17781328c21df0c60300524|2.1.1-git"
  "libtatsu|https://github.com/libimobiledevice/libtatsu.git|e7d6ad13ef928aa609d0ccdfc586f7d6e8e049bf|1.0.5-git"
  "libimobiledevice|https://github.com/libimobiledevice/libimobiledevice.git|fa0f79190142bc309307967c058f89c1b36eb6b8|1.4.0-git"
  "libirecovery|https://github.com/libimobiledevice/libirecovery.git|93c117c29b1f6669bc4ceca8b84e1df06449fe33|1.3.1-git"
  "idevicerestore|https://github.com/libimobiledevice/idevicerestore.git|60192e97f87d1bbab5c493684e0a245b0966363f|1.0.0-git"
  "libzip|https://github.com/nih-at/libzip.git|6f8a0cdd24a0dc6cce9dac4a7679da784ab124ea|1.11.4"
)
OPENSSL_VERSION=3.5.8
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2

for tool in autoconf automake glibtoolize pkg-config cmake git xcrun lipo; do
  command -v "$tool" >/dev/null || fail "$tool is missing (brew install autoconf automake libtool pkg-config cmake)"
done
SDK="$(xcrun --sdk macosx --show-sdk-path)"

fetch_sources() {
  mkdir -p "$SRC"
  for entry in "${GIT_SOURCES[@]}"; do
    IFS='|' read -r name url commit version <<<"$entry"
    local dir="$SRC/$name"
    if [[ -d "$dir/.git" && "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]]; then continue; fi
    step "Fetching $name @ ${commit:0:12}"
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]] || fail "$name is not at the pinned commit"
    echo "$version" > "$dir/.tarball-version"
  done
  local tarball="$SRC/openssl-$OPENSSL_VERSION.tar.gz"
  if [[ ! -f "$tarball" ]]; then
    step "Downloading OpenSSL $OPENSSL_VERSION"
    curl -fsSL -o "$tarball.part" "$OPENSSL_URL"
    mv "$tarball.part" "$tarball"
  fi
  echo "$OPENSSL_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || fail "OpenSSL tarball checksum mismatch"
}

# autotools project: name, extra configure flags…
build_autotools() {
  local arch="$1" name="$2"; shift 2
  local prefix="$WORK/prefix-$arch" build="$WORK/build-$arch/$name"
  [[ -f "$build/.done" ]] && return 0
  step "[$arch] $name"
  rm -rf "$build"; mkdir -p "$build"
  cp -R "$SRC/$name/." "$build/"
  (
    cd "$build"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export CC="$(xcrun -f clang) -arch $arch -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"
    export CFLAGS="-O2" CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib"
    export LIBTOOLIZE=glibtoolize
    NOCONFIGURE=1 ./autogen.sh >"$build/autogen.log" 2>&1 || { tail -30 "$build/autogen.log"; exit 1; }
    ./configure --host="$([[ $arch == arm64 ]] && echo aarch64 || echo x86_64)-apple-darwin" --prefix="$prefix" \
      --enable-static --disable-shared "$@" >"$build/configure.log" 2>&1 || { tail -40 "$build/configure.log"; exit 1; }
    make -j"$JOBS" >"$build/make.log" 2>&1 || { grep -E "error" "$build/make.log" | head -20; tail -20 "$build/make.log"; exit 1; }
    make install >"$build/install.log" 2>&1
  )
  touch "$build/.done"
}

build_openssl() {
  local arch="$1" prefix="$WORK/prefix-$arch" build="$WORK/build-$arch/openssl"
  [[ -f "$build/.done" ]] && return 0
  step "[$arch] OpenSSL $OPENSSL_VERSION"
  rm -rf "$build"; mkdir -p "$build"
  tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$build" --strip-components 1
  (
    cd "$build"
    ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs no-module --prefix="$prefix" --libdir=lib \
      -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS" >"$build/configure.log" 2>&1 || { tail -30 "$build/configure.log"; exit 1; }
    make -j"$JOBS" build_libs >"$build/make.log" 2>&1 || { tail -30 "$build/make.log"; exit 1; }
    make install_dev >"$build/install.log" 2>&1
  )
  touch "$build/.done"
}

build_libzip() {
  local arch="$1" prefix="$WORK/prefix-$arch" build="$WORK/build-$arch/libzip"
  [[ -f "$build/.done" ]] && return 0
  step "[$arch] libzip"
  rm -rf "$build"; mkdir -p "$build"
  cmake -S "$SRC/libzip" -B "$build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_COMMONCRYPTO=ON -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF \
    -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF >"$build/cmake.log" 2>&1 || { tail -30 "$build/cmake.log"; exit 1; }
  cmake --build "$build" -j "$JOBS" >"$build/make.log" 2>&1 || { tail -30 "$build/make.log"; exit 1; }
  cmake --install "$build" >"$build/install.log" 2>&1
  touch "$build/.done"
}

# pkg-config files for the libraries macOS provides (curl and zlib from the SDK).
system_pkgconfig() {
  local prefix="$WORK/prefix-$1"
  mkdir -p "$prefix/lib/pkgconfig"
  cat > "$prefix/lib/pkgconfig/libcurl.pc" <<EOF
Name: libcurl
Description: libcurl (macOS SDK)
Version: 8.0.0
Libs: -lcurl
Cflags:
EOF
  cat > "$prefix/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib (macOS SDK)
Version: 1.2.12
Libs: -lz
Cflags:
EOF
}

build_arch() {
  local arch="$1"
  system_pkgconfig "$arch"
  build_openssl "$arch"
  build_libzip "$arch"
  build_autotools "$arch" libplist --without-cython --without-tests
  build_autotools "$arch" libimobiledevice-glue
  build_autotools "$arch" libusbmuxd --without-preflight
  build_autotools "$arch" libtatsu
  build_autotools "$arch" libimobiledevice --without-cython --enable-debug=no
  build_autotools "$arch" libirecovery --with-tools
  build_autotools "$arch" idevicerestore
}

fetch_sources
for arch in arm64 x86_64; do build_arch "$arch"; done

step "Combining architectures"
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/licenses"
for tool in idevicerestore irecovery; do
  lipo -create "$WORK/prefix-arm64/bin/$tool" "$WORK/prefix-x86_64/bin/$tool" -output "$OUT/bin/$tool"
  archs="$(lipo -archs "$OUT/bin/$tool")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$tool is not universal ($archs)"
  # Only macOS system libraries may remain dynamic.
  # (otool prints a header line ending in ":" for each architecture.)
  if otool -L "$OUT/bin/$tool" | grep -v ':$' | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)'; then
    fail "$tool links a non-system library (listed above)"
  fi
done

step "Licenses and sources"
for entry in "${GIT_SOURCES[@]}"; do
  IFS='|' read -r name url commit version <<<"$entry"
  mkdir -p "$OUT/licenses/$name"
  for file in COPYING COPYING.LESSER LICENSE AUTHORS NOTICE; do
    [[ -f "$SRC/$name/$file" ]] && cp "$SRC/$name/$file" "$OUT/licenses/$name/"
  done
  echo "$name $version $url @ $commit" >> "$OUT/SOURCES.txt"
done
mkdir -p "$OUT/licenses/openssl"
tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$OUT/licenses/openssl" --strip-components 1 "openssl-$OPENSSL_VERSION/LICENSE.txt"
echo "openssl $OPENSSL_VERSION $OPENSSL_URL sha256 $OPENSSL_SHA256" >> "$OUT/SOURCES.txt"
shasum -a 256 "$ROOT/scripts/build-restore-helpers.sh" | cut -d' ' -f1 > "$OUT/STAMP"

step "Done: $OUT"
ls -l "$OUT/bin"
