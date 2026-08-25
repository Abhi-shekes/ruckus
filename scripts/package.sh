#!/usr/bin/env bash
#
# Build distributable packages.
#
#   scripts/package.sh deb        → dist/ruckus_<version>_amd64.deb
#   scripts/package.sh appimage   → dist/Ruckus-<version>-x86_64.AppImage
#   scripts/package.sh all
#
# Both formats ship a self-contained /opt-style tree, because flutter_soloud
# bakes an absolute RUNPATH pointing at the build machine's source directory.
# On any other machine that path does not exist, so its audio codecs must be
# copied in beside the app and reached through LD_LIBRARY_PATH from a launcher.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
DIST="$ROOT/dist"
VERSION="$(grep -m1 '^version:' "$APP/pubspec.yaml" | sed 's/version: *//; s/+.*//')"
ARCH="amd64"

log() { printf '\033[36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- shared

build_release() {
  log "Building release (v$VERSION)"
  (cd "$APP" && flutter build linux --release >/dev/null) || die "flutter build failed"
  [[ -x "$APP/build/linux/x64/release/bundle/ruckus" ]] || die "no release binary"
}

# Assembles the app tree at $1, self-contained.
stage_payload() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -r "$APP/build/linux/x64/release/bundle/." "$dest/"

  # flutter_soloud's codecs live outside the bundle, behind an absolute
  # RUNPATH. Copy them in so the package does not depend on the build tree.
  local soloud="$APP/linux/flutter/ephemeral/.plugin_symlinks/flutter_soloud/linux/libs"
  if [[ -d "$soloud" ]]; then
    cp -a "$soloud/"lib*.so* "$dest/lib/" 2>/dev/null || true
  fi

  # …then replace libFLAC outright with the build that does not require
  # glibc 2.34, so the package also runs on Ubuntu 20.04. Every variant of the
  # upstream one goes, or the incompatible copy ships alongside ours.
  if [[ -f "$APP/linux/prebuilt/glibc231/libFLAC.so.14" ]]; then
    rm -f "$dest/lib/"libFLAC.so*
    cp -f "$APP/linux/prebuilt/glibc231/libFLAC.so.14" "$dest/lib/libFLAC.so.14"
    ln -sf libFLAC.so.14 "$dest/lib/libFLAC.so"
  fi

  log "  payload: $(du -sh "$dest" | cut -f1)"
}

# Launcher that puts the bundled libs first and supplies the unversioned
# sqlite name sqflite_common_ffi insists on opening.
write_launcher() {
  local path="$1" libdir="$2" binary="$3"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LIBDIR="$libdir"

# sqflite_common_ffi opens the unversioned name, which only exists when
# libsqlite3-dev is installed. Point at whatever the system already ships.
if [[ ! -e "\$LIBDIR/libsqlite3.so" ]]; then
  for c in /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /usr/lib/libsqlite3.so.0 \\
           /lib/x86_64-linux-gnu/libsqlite3.so.0; do
    [[ -e "\$c" ]] && ln -sf "\$c" "\$LIBDIR/libsqlite3.so" 2>/dev/null && break
  done
fi

export LD_LIBRARY_PATH="\$LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$binary" "\$@"
EOF
  chmod +x "$path"
}

write_desktop() {
  local path="$1" exec_line="$2" icon="$3"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
[Desktop Entry]
Type=Application
Name=Ruckus
GenericName=Soundboard
Comment=Bind a sound to a key and press it from any application
Exec=$exec_line
Icon=$icon
Terminal=false
Categories=AudioVideo;Audio;
Keywords=soundboard;audio;hotkey;sfx;
StartupWMClass=ruckus
EOF
}

# ------------------------------------------------------------------- deb

make_deb() {
  local stage="$DIST/deb"
  local pkg="$DIST/ruckus_${VERSION}_${ARCH}.deb"
  log "Packaging .deb"

  rm -rf "$stage"
  stage_payload "$stage/opt/ruckus"

  write_launcher "$stage/usr/bin/ruckus" "/opt/ruckus/lib" "/opt/ruckus/ruckus"
  write_desktop "$stage/usr/share/applications/ruckus.desktop" "ruckus" "ruckus"

  mkdir -p "$stage/usr/share/icons/hicolor/256x256/apps"
  cp "$ROOT/packaging/ruckus.png" \
     "$stage/usr/share/icons/hicolor/256x256/apps/ruckus.png"

  mkdir -p "$stage/usr/share/doc/ruckus"
  cp "$ROOT/README.md" "$stage/usr/share/doc/ruckus/"
  cp "$ROOT/LICENSE" "$stage/usr/share/doc/ruckus/copyright"

  local size_kb
  size_kb="$(du -sk "$stage" | cut -f1)"

  mkdir -p "$stage/DEBIAN"
  cat > "$stage/DEBIAN/control" <<EOF
Package: ruckus
Version: $VERSION
Section: sound
Priority: optional
Architecture: $ARCH
Installed-Size: $size_kb
Depends: libgtk-3-0, libx11-6, libxtst6, libsqlite3-0, libxkbcommon0, libasound2 | libpulse0
Maintainer: Abhishek <abhishekshivtiwari@gmail.com>
Homepage: https://github.com/Abhi-shekes/ruckus
Description: Desktop soundboard with global hotkeys
 Bind a sound to a key and press it from any application - a game, a browser,
 a call. Sounds are decoded into memory at startup so playback is immediate,
 and presses overlap rather than cutting each other off.
 .
 Global keys use the X11 XRecord extension, which needs no special permissions.
 Nothing about your keystrokes is stored or transmitted; the application
 contains no network code.
EOF

  cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
# The launcher needs to be able to drop a symlink beside the bundled libs.
chmod 0775 /opt/ruckus/lib 2>/dev/null || true
exit 0
EOF
  chmod 0755 "$stage/DEBIAN/postinst"

  cat > "$stage/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
rm -f /opt/ruckus/lib/libsqlite3.so 2>/dev/null || true
exit 0
EOF
  chmod 0755 "$stage/DEBIAN/prerm"

  dpkg-deb --build --root-owner-group "$stage" "$pkg" >/dev/null
  log "  → $pkg ($(du -h "$pkg" | cut -f1))"
}

# -------------------------------------------------------------- appimage

make_appimage() {
  local stage="$DIST/Ruckus.AppDir"
  log "Packaging AppImage"

  rm -rf "$stage"
  stage_payload "$stage/usr/lib/ruckus"

  write_launcher "$stage/usr/bin/ruckus" \
    '$APPDIR/usr/lib/ruckus/lib' '$APPDIR/usr/lib/ruckus/ruckus'

  # AppRun is what the AppImage runtime executes.
  cat > "$stage/AppRun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APPDIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export APPDIR
exec "$APPDIR/usr/bin/ruckus" "$@"
EOF
  chmod +x "$stage/AppRun"

  write_desktop "$stage/ruckus.desktop" "ruckus" "ruckus"
  cp "$ROOT/packaging/ruckus.png" "$stage/ruckus.png"
  mkdir -p "$stage/usr/share/icons/hicolor/256x256/apps"
  cp "$ROOT/packaging/ruckus.png" \
     "$stage/usr/share/icons/hicolor/256x256/apps/ruckus.png"

  local tool="$DIST/appimagetool"
  if [[ ! -x "$tool" ]]; then
    log "  fetching appimagetool"
    curl -sL --max-time 120 -o "$tool" \
      "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" \
      && chmod +x "$tool" || true
  fi

  if [[ -x "$tool" ]]; then
    # No FUSE in many CI and container environments; extract-and-run avoids it.
    if ARCH=x86_64 "$tool" --appimage-extract-and-run "$stage" \
         "$DIST/Ruckus-${VERSION}-x86_64.AppImage" >/dev/null 2>&1; then
      log "  → $DIST/Ruckus-${VERSION}-x86_64.AppImage"
      return
    fi
  fi

  log "  appimagetool unavailable — AppDir left at $stage"
  log "  build it later with: appimagetool $stage"
}

mkdir -p "$DIST"
case "${1:-all}" in
  deb)      build_release; make_deb ;;
  appimage) build_release; make_appimage ;;
  all)      build_release; make_deb; make_appimage ;;
  *)        die "usage: $0 [deb|appimage|all]" ;;
esac

log "Done. Artefacts in $DIST"
