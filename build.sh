#!/usr/bin/env bash
#
# Pour — build, bundle, sign, run.
#
#   ./build.sh run       build + bundle + sign + launch in the foreground (logs to stderr)
#   ./build.sh app       build + bundle + sign only
#   ./build.sh doctor    check the toolchain and signing identity
#   ./build.sh reset     revoke Pour's TCC grants so you can re-test the permission flow
#   ./build.sh clean
#
# Signing: set SIGN_ID to a codesigning identity, or let the script find your
# "Developer ID Application" or Pour local-development cert. It falls back to
# ad-hoc ("-"), which builds and runs fine but makes macOS forget your
# Accessibility grant on every rebuild.

set -euo pipefail

APP_NAME="Pour"
BUNDLE_ID="com.brewedai.pour"
CONFIG="${CONFIG:-release}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
BINARY="$ROOT/.build/$CONFIG/$APP_NAME"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

identity() {
  if [[ -n "${SIGN_ID:-}" ]]; then
    printf '%s' "$SIGN_ID"
    return
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -E 's/.*"(.+)".*/\1/')" || true
  if [[ -z "$found" ]]; then
    found="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep '"Pour Local Code Signing"' \
      | head -1 \
      | sed -E 's/.*"(.+)".*/\1/')" || true
  fi
  printf '%s' "${found:--}"
}

cmd_build() {
  command -v swift >/dev/null || die "swift not found. Install Xcode 26 and run: sudo xcode-select -s /Applications/Xcode.app"
  bold "Building ($CONFIG)…"
  swift build -c "$CONFIG" --product "$APP_NAME"
}

cmd_bundle() {
  [[ -x "$BINARY" ]] || die "No binary at $BINARY — run ./build.sh app"
  bold "Assembling $APP_NAME.app…"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ditto "$ROOT/Sources/DesignKit/Resources/Fonts" "$APP/Contents/Resources/Fonts"
  # Package dependency resources belong in the standard macOS Resources folder.
  local resource_bundle bundle_name
  for resource_bundle in "$ROOT/.build/$CONFIG/"*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    bundle_name="$(basename "$resource_bundle")"
    [[ "$bundle_name" == "Pour_DesignKit.bundle" ]] && continue
    ditto "$resource_bundle" "$APP/Contents/Resources/$bundle_name"
  done
  printf 'APPL????' > "$APP/Contents/PkgInfo"
}

cmd_verify_bundle() {
  local fonts="$APP/Contents/Resources/Fonts"
  [[ -f "$fonts/Inter-Variable.ttf" ]] || die "The app is missing its DesignKit font resources."
  [[ -f "$fonts/Fraunces-Variable.ttf" ]] || die "The app is missing its DesignKit font resources."
  [[ -f "$fonts/JetBrainsMono-Variable.ttf" ]] || die "The app is missing its DesignKit font resources."
}

cmd_sign() {
  local ident
  ident="$(identity)"
  if [[ "$ident" == "-" ]]; then
    warn "Signing ad-hoc. macOS will treat every rebuild as a new app and drop your"
    warn "Accessibility grant — expect to re-approve Pour after each build."
    warn "Fix: SIGN_ID=\"Developer ID Application: Your Name (TEAMID)\" ./build.sh run"
  else
    bold "Signing as: $ident"
  fi
  codesign --force --options runtime \
    --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
    --sign "$ident" \
    "$APP"
  codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
}

cmd_app() {
  cmd_build
  cmd_bundle
  cmd_verify_bundle
  cmd_sign
  bold "Built $APP"
}

cmd_run() {
  cmd_app
  bold "Launching. Hold \` to dictate, Esc to cancel, ⌃C here to quit."
  exec "$APP/Contents/MacOS/$APP_NAME"
}

cmd_doctor() {
  bold "Toolchain"
  printf '  swift      %s\n' "$(swift --version 2>/dev/null | head -1 || echo 'MISSING')"
  printf '  xcode      %s\n' "$(xcode-select -p 2>/dev/null || echo 'MISSING')"
  printf '  macOS      %s\n' "$(sw_vers -productVersion)"
  bold "Signing"
  printf '  identity   %s\n' "$(identity)"
  bold "Permissions"
  printf '  Pour needs Accessibility (event tap + text injection) and Microphone.\n'
  printf '  Check: System Settings → Privacy & Security → Accessibility\n'
}

cmd_reset() {
  bold "Revoking TCC grants for $BUNDLE_ID…"
  tccutil reset Accessibility "$BUNDLE_ID" || true
  tccutil reset Microphone "$BUNDLE_ID" || true
  tccutil reset ListenEvent "$BUNDLE_ID" || true
  bold "Done. Next launch will prompt again."
}

cmd_clean() {
  rm -rf "$ROOT/.build" "$BUILD_DIR"
  bold "Cleaned."
}

case "${1:-run}" in
  run)    cmd_run ;;
  app)    cmd_app ;;
  build)  cmd_build ;;
  doctor) cmd_doctor ;;
  reset)  cmd_reset ;;
  clean)  cmd_clean ;;
  *)      die "Unknown command: $1 (try: run, app, doctor, reset, clean)" ;;
esac
