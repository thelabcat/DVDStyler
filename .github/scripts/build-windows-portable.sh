#!/usr/bin/env bash
# Build a portable Windows x64 zip of DVDStyler with MSYS2 (UCRT64).
#
# Run from the root of a DVDStyler checkout in an MSYS2 UCRT64 shell
# (msys2/setup-msys2 in CI). wxWidgets 3.2, FFmpeg, wxSVG, libexif and
# fontconfig come from MSYS2 packages; their DLLs are collected recursively
# from /ucrt64/bin. Anything not found there is a Windows system DLL.
#
# External programs DVDStyler runs:
#   ffmpeg.exe              MSYS2 mingw-w64-ucrt-x86_64-ffmpeg (same build as the libraries)
#   dvdauthor.exe/spumux.exe built here from github.com/ldo/dvdauthor (no MSYS2 package)
#   mkisofs.exe, growisofs.exe, dvd+rw-format.exe, dvd+rw-mediainfo.exe
#                           taken unchanged from upstream's official DVDStyler 3.2.1
#                           win64 installer (no MSYS2 package; cdrtools does not
#                           build with MinGW). These are 32-bit builds.
#
# Layout of the zip (what DVDStyler expects on Windows, see
# wxFindDataDirectory and Config::Init):
#   DVDStyler-<ver>-win64/DVDStyler.ini   portable settings (exe dir/..)
#   DVDStyler-<ver>-win64/bin/            DVDStyler.exe, tools, DLLs
#   DVDStyler-<ver>-win64/{backgrounds,buttons,data,docs,objects,templates,transitions,locale}
#   DVDStyler-<ver>-win64/etc/fonts/      fontconfig config (bin/../etc/fonts)
#
# Usage: build-windows-portable.sh [deps|tools|build|package|all]
# Environment: DEPS_PREFIX (cacheable, default /c/dvdstyler-deps), OUT_DIR, JOBS
set -euo pipefail

DVDAUTHOR_COMMIT=${DVDAUTHOR_COMMIT:-fe8fe3578f95f34889e7ed17591d02dceb4f42ed}
WXSVG_VERSION=${WXSVG_VERSION:-1.5.25}
UPSTREAM_INSTALLER_URL=https://downloads.sourceforge.net/project/dvdstyler/dvdstyler/3.2.1/DVDStyler-3.2.1-win64.exe
UPSTREAM_INSTALLER_SHA256=99b74055e9b5cceae29b153158563e454905531c966f3cdbe98ea390a6a0e713
DEPS_PREFIX=${DEPS_PREFIX:-/c/dvdstyler-deps}
OUT_DIR=${OUT_DIR:-$PWD/dist}
JOBS=${JOBS:-$(nproc)}
SRC_DIR=$PWD
WORK=${WORK:-/c/dvdstyler-work}
STAGE=$WORK/stage

VERSION=$(sed -n 's/^AC_INIT(\[DVDStyler\],\[\([^]]*\)\].*/\1/p' configure.ac)
[ -n "$VERSION" ] || { echo "cannot read version from configure.ac" >&2; exit 1; }
NAME=DVDStyler-$VERSION-win64

export PATH=$DEPS_PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$DEPS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}

step() { echo; echo "=== $* ==="; }

wxsvg_has_ffmpeg() {
  # DVDStyler needs wxSVG's FFmpeg media decoder.
  local lib
  for lib in "$DEPS_PREFIX"/lib/libwxsvg*.dll.a /ucrt64/lib/libwxsvg*.dll.a; do
    [ -e "$lib" ] && nm "$lib" 2>/dev/null | grep -q wxFfmpegMediaDecoder && return 0
  done
  return 1
}

build_deps() {
  mkdir -p "$DEPS_PREFIX" "$WORK"
  if [ ! -x "$DEPS_PREFIX/bin/dvdauthor.exe" ]; then
    step "Building dvdauthor ($DVDAUTHOR_COMMIT)"
    rm -rf "$WORK/dvdauthor"
    git clone -q https://github.com/ldo/dvdauthor.git "$WORK/dvdauthor"
    cd "$WORK/dvdauthor"
    git checkout -q "$DVDAUTHOR_COMMIT"
    patch -p1 < "$SRC_DIR/.github/patches/dvdauthor-mingw.patch"
    # Same as dvdauthor's ./bootstrap: autoreconf needs gettext's config.rpath.
    mkdir -p autotools m4
    cp "$(ls /usr/share/gettext*/config.rpath /ucrt64/share/gettext*/config.rpath 2>/dev/null | head -1)" autotools/
    autoreconf -fi
    ./configure --prefix="$DEPS_PREFIX" --disable-dvdunauthor
    # Only the two programs DVDStyler runs. The man pages need docbook2man
    # (not in MSYS2) and mpeg2desc uses select() on pipes, which MinGW lacks.
    make -C src -j"$JOBS" dvdauthor.exe spumux.exe
    mkdir -p "$DEPS_PREFIX/bin"
    cp src/dvdauthor.exe src/spumux.exe "$DEPS_PREFIX/bin/"
    cd "$SRC_DIR"
  fi
  "$DEPS_PREFIX/bin/dvdauthor.exe" -h 2>&1 | head -3 || true

  if ! wxsvg_has_ffmpeg; then
    step "MSYS2 wxSVG lacks FFmpeg support; building wxSVG $WXSVG_VERSION"
    cd "$WORK"
    curl -fsSL -o wxsvg.tar.bz2 "https://downloads.sourceforge.net/project/wxsvg/wxsvg/$WXSVG_VERSION/wxsvg-$WXSVG_VERSION.tar.bz2"
    rm -rf "wxsvg-$WXSVG_VERSION" && tar -xjf wxsvg.tar.bz2
    cd "wxsvg-$WXSVG_VERSION"
    ./configure --prefix="$DEPS_PREFIX" --enable-shared --disable-static --with-wx-config=wx-config
    make -j"$JOBS"
    make install
    cd "$SRC_DIR"
    wxsvg_has_ffmpeg || { echo "wxSVG still has no FFmpeg decoder" >&2; exit 1; }
  else
    echo "wxSVG with FFmpeg support found"
  fi
}

fetch_upstream_tools() {
  step "Fetching mkisofs/growisofs from upstream DVDStyler 3.2.1"
  local d=$DEPS_PREFIX/upstream-3.2.1
  if [ ! -x "$d/mkisofs.exe" ]; then
    mkdir -p "$WORK/upstream" "$d"
    cd "$WORK/upstream"
    curl -fsSL --retry 3 -o installer.exe "$UPSTREAM_INSTALLER_URL"
    echo "$UPSTREAM_INSTALLER_SHA256  installer.exe" | sha256sum -c -
    innoextract -s -d x installer.exe
    for f in mkisofs.exe growisofs.exe dvd+rw-format.exe dvd+rw-mediainfo.exe libgcc_s_dw2-1.dll; do
      cp "x/app/bin/$f" "$d/$f"
    done
    cd "$SRC_DIR"
  fi
  # Put them on PATH so configure's checks find them.
  cp -u "$d"/*.exe "$d"/*.dll "$DEPS_PREFIX/bin/"
  ls -l "$d"
}

build_dvdstyler() {
  step "Building DVDStyler $VERSION"
  cd "$SRC_DIR"
  ./autogen.sh
  ./configure --prefix="$STAGE" --with-wx-config=wx-config
  # Help zips serially: parallel zip runs in docs/ clobber each other's
  # temp files on Windows.
  make -C docs -j1
  # -k: report every compile error in one run
  make -k -j"$JOBS"
  rm -rf "$STAGE"
  make install
}

is_system_dll() {
  # A DLL is bundled if MSYS2 (or our prefix) has it; everything else comes
  # from Windows.
  [ ! -e "/ucrt64/bin/$1" ] && [ ! -e "$DEPS_PREFIX/bin/$1" ]
}

assemble() {
  step "Assembling $NAME"
  local B=$WORK/$NAME
  rm -rf "$B" && mkdir -p "$B/bin" "$B/etc"
  cp "$STAGE/bin/dvdstyler.exe" "$B/bin/DVDStyler.exe"
  cp /ucrt64/bin/ffmpeg.exe /ucrt64/bin/ffprobe.exe "$B/bin/"
  cp "$DEPS_PREFIX/bin/dvdauthor.exe" "$DEPS_PREFIX/bin/spumux.exe" "$B/bin/"
  cp "$DEPS_PREFIX"/upstream-3.2.1/* "$B/bin/"
  # Windows helper files upstream ships next to the exe (ffmpeg-vbr encoder).
  cp "$SRC_DIR"/src/*.bat "$SRC_DIR"/src/ff_vbr.* "$SRC_DIR"/src/*.txt "$B/bin/"
  cp -r "$SRC_DIR/src/German" "$B/bin/"
  # Data dirs sit next to bin/ (DVDStyler looks in <exe dir>/../<dir>).
  cp -a "$STAGE/share/dvdstyler/." "$B/"
  cp -a "$STAGE/share/locale" "$B/locale"
  cp -a /ucrt64/etc/fonts "$B/etc/fonts"
  cp "$SRC_DIR/COPYING" "$SRC_DIR/README" "$SRC_DIR/ChangeLog" "$B/"
  printf '[Interface]\r\nLanguageCode=en\r\n' > "$B/DVDStyler.ini"

  # Collect the DLLs the executables import, recursively.
  local queue=("$B"/bin/DVDStyler.exe "$B"/bin/ffmpeg.exe "$B"/bin/ffprobe.exe "$B"/bin/dvdauthor.exe "$B"/bin/spumux.exe)
  local f dll src
  while [ ${#queue[@]} -gt 0 ]; do
    f=${queue[0]}; queue=("${queue[@]:1}")
    for dll in $(objdump -p "$f" | awk '/DLL Name:/{print $3}'); do
      [ -e "$B/bin/$dll" ] && continue
      is_system_dll "$dll" && continue
      if [ -e "$DEPS_PREFIX/bin/$dll" ]; then src=$DEPS_PREFIX/bin/$dll; else src=/ucrt64/bin/$dll; fi
      cp "$src" "$B/bin/$dll"
      queue+=("$B/bin/$dll")
    done
  done
  strip --strip-unneeded "$B/bin/DVDStyler.exe" "$B/bin/dvdauthor.exe" "$B/bin/spumux.exe" || true

  write_readme "$B"

  mkdir -p "$OUT_DIR"
  rm -f "$OUT_DIR/$NAME.zip"
  (cd "$WORK" && zip -qr9 "$OUT_DIR/$NAME.zip" "$NAME")
  (cd "$OUT_DIR" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
  ls -l "$OUT_DIR"
  echo "DLLs bundled: $(ls "$B"/bin/*.dll | wc -l)"
}

write_readme() {
  local B=$1
  {
    echo "DVDStyler $VERSION - portable Windows x64 build"
    echo
    echo "Unzip anywhere (not under C:\\Program Files) and run bin\\DVDStyler.exe."
    echo "Settings are kept in DVDStyler.ini in this folder, not in the registry."
    echo
    echo "Built with MSYS2 UCRT64: $(gcc --version | head -1)"
    echo "Bundled libraries (from MSYS2): wxWidgets $(wx-config --version), FFmpeg $(pkg-config --modversion libavformat) (libavformat), wxSVG, libexif, fontconfig and their dependencies."
    echo
    echo "External programs in bin\\:"
    echo "  ffmpeg.exe, ffprobe.exe  MSYS2 mingw-w64-ucrt-x86_64-ffmpeg"
    echo "  dvdauthor.exe, spumux.exe  dvdauthor (github.com/ldo/dvdauthor $DVDAUTHOR_COMMIT), built with MSYS2"
    echo "  mkisofs.exe, growisofs.exe, dvd+rw-format.exe, dvd+rw-mediainfo.exe, libgcc_s_dw2-1.dll"
    echo "      unchanged 32-bit binaries from the official DVDStyler 3.2.1 win64 installer"
    echo "      (mkisofs 2.01-bootcd.ru from cdrtools, growisofs 7.1 from dvd+rw-tools; GPL)"
    echo
    echo "Windows 10 or newer is required (UCRT)."
  } > "$B/README-WINDOWS.txt"
  sed -i 's/$/\r/' "$B/README-WINDOWS.txt"
}

case "${1:-all}" in
  deps) build_deps ;;
  tools) fetch_upstream_tools ;;
  build) build_dvdstyler ;;
  package) assemble ;;
  all) build_deps; fetch_upstream_tools; build_dvdstyler; assemble ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
