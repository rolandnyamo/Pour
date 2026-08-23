#!/usr/bin/env bash
#
# Build Pour from source, install it for the current macOS user, and launch it.
#
#   curl -fsSL https://raw.githubusercontent.com/Brewed-Craig/Pour/main/install.sh | bash
#
# Optional overrides for maintainers and testers:
#   POUR_REPOSITORY=owner/Pour  GitHub repository to download
#   POUR_REF=branch-or-tag       Git ref to build (default: main)
#   POUR_INSTALL_DIR=/path      Destination directory (default: ~/Applications)
#   POUR_LAUNCH=0               Install without launching

set -euo pipefail

APP_NAME="Pour"
BUNDLE_ID="com.brewedai.pour"
POUR_REPOSITORY="${POUR_REPOSITORY:-Brewed-Craig/Pour}"
POUR_REF="${POUR_REF:-main}"
POUR_INSTALL_DIR="${POUR_INSTALL_DIR:-$HOME/Applications}"
POUR_LAUNCH="${POUR_LAUNCH:-1}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but wasn't found."
}

validate_environment() {
  [[ "$(uname -m)" == "arm64" ]] || die "Pour requires an Apple Silicon Mac."

  local macos_version macos_major xcode_version xcode_major
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  [[ "$macos_major" =~ ^[0-9]+$ ]] || die "Couldn't determine the macOS version."
  (( macos_major >= 26 )) || die "Pour requires macOS 26 or newer (this Mac has $macos_version)."

  require_command curl
  require_command tar
  require_command ditto
  require_command codesign
  require_command plutil
  require_command xcodebuild
  require_command swift

  xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
  xcode_major="${xcode_version%%.*}"
  [[ "$xcode_major" =~ ^[0-9]+$ ]] || die "Couldn't determine the Xcode version."
  (( xcode_major >= 26 )) || die "Pour requires Xcode 26 or newer (this Mac has $xcode_version)."

  case "$POUR_INSTALL_DIR" in
    /*) ;;
    *) die "POUR_INSTALL_DIR must be an absolute path." ;;
  esac
  [[ "$POUR_INSTALL_DIR" != "/" ]] || die "Refusing to use the filesystem root as an install directory."
}

validate_repository() {
  [[ "$POUR_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "POUR_REPOSITORY must look like owner/repository."
  [[ -n "$POUR_REF" && "$POUR_REF" != -* ]] || die "POUR_REF is invalid."
}

validate_environment
validate_repository

POUR_TEMP_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/pour-install.XXXXXX")"
POUR_ARCHIVE="$POUR_TEMP_DIR/source.tar.gz"
POUR_SOURCE_ROOT="$POUR_TEMP_DIR/source"
POUR_STAGED_APP=""
POUR_BACKUP_APP=""
POUR_TARGET_APP=""

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && -n "$POUR_BACKUP_APP" && -e "$POUR_BACKUP_APP" \
        && -n "$POUR_TARGET_APP" && ! -e "$POUR_TARGET_APP" ]]; then
    if mv "$POUR_BACKUP_APP" "$POUR_TARGET_APP"; then
      POUR_BACKUP_APP=""
      warn "Installation was interrupted; the previous Pour app was restored."
    else
      warn "Couldn't restore the previous app. Its backup remains at $POUR_BACKUP_APP"
    fi
  fi
  if [[ -n "$POUR_STAGED_APP" && -e "$POUR_STAGED_APP" ]]; then
    rm -rf "$POUR_STAGED_APP"
  fi
  # Never delete a backup from the EXIT trap. If restoring a prior installation
  # fails, leaving that backup behind is safer than making the failure irreversible.
  rm -rf "$POUR_TEMP_DIR"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bold "Downloading $POUR_REPOSITORY at ${POUR_REF}…"
mkdir -p "$POUR_SOURCE_ROOT"
curl --fail --location --retry 3 --show-error --silent \
  "https://api.github.com/repos/$POUR_REPOSITORY/tarball/$POUR_REF" \
  --output "$POUR_ARCHIVE"
tar -xzf "$POUR_ARCHIVE" -C "$POUR_SOURCE_ROOT"

POUR_SOURCE_DIR="$(find "$POUR_SOURCE_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$POUR_SOURCE_DIR" && -x "$POUR_SOURCE_DIR/build.sh" ]] \
  || die "The downloaded source archive doesn't contain build.sh."

bold "Building Pour…"
(
  cd "$POUR_SOURCE_DIR"
  ./build.sh app
)

POUR_BUILT_APP="$POUR_SOURCE_DIR/build/$APP_NAME.app"
[[ -d "$POUR_BUILT_APP" ]] || die "The build completed without producing $APP_NAME.app."
[[ -f "$POUR_BUILT_APP/Contents/Resources/Fonts/Inter-Variable.ttf" ]] \
  || die "The built app is missing its required DesignKit resources."
POUR_BUILT_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$POUR_BUILT_APP/Contents/Info.plist")"
[[ "$POUR_BUILT_BUNDLE_ID" == "$BUNDLE_ID" ]] \
  || die "The built app has an unexpected bundle identifier: $POUR_BUILT_BUNDLE_ID"
codesign --verify "$POUR_BUILT_APP" || die "The built app's signature is invalid."

mkdir -p "$POUR_INSTALL_DIR"
POUR_TARGET_APP="$POUR_INSTALL_DIR/$APP_NAME.app"
POUR_STAGED_APP="$POUR_INSTALL_DIR/.$APP_NAME.installing.$$"
POUR_BACKUP_APP="$POUR_INSTALL_DIR/.$APP_NAME.backup.$$"

bold "Installing ${POUR_TARGET_APP}…"
ditto --noextattr --noqtn "$POUR_BUILT_APP" "$POUR_STAGED_APP"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
  for _ in 1 2 3 4 5; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 1
  done
fi

if [[ -e "$POUR_TARGET_APP" ]]; then
  mv "$POUR_TARGET_APP" "$POUR_BACKUP_APP"
fi

if mv "$POUR_STAGED_APP" "$POUR_TARGET_APP"; then
  POUR_STAGED_APP=""
  if [[ -e "$POUR_BACKUP_APP" ]]; then
    rm -rf "$POUR_BACKUP_APP"
  fi
  POUR_BACKUP_APP=""
else
  if [[ -e "$POUR_BACKUP_APP" ]]; then
    mv "$POUR_BACKUP_APP" "$POUR_TARGET_APP"
    POUR_BACKUP_APP=""
  fi
  die "Installation failed; the previous app was restored."
fi

codesign --verify "$POUR_TARGET_APP" || die "The installed app's signature is invalid."
[[ -f "$POUR_TARGET_APP/Contents/Resources/Fonts/Inter-Variable.ttf" ]] \
  || die "The installed app is missing its required DesignKit resources."

bold "Installed Pour successfully."
POUR_SIGNATURE_INFO="$(codesign -dvv "$POUR_TARGET_APP" 2>&1 || true)"
if [[ "$POUR_SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  warn "This build is ad-hoc signed. Create the free 'Pour Local Code Signing'"
  warn "certificate described in the README before reinstalling to keep permissions across updates."
fi

if [[ "$POUR_LAUNCH" != "0" ]]; then
  bold "Launching Pour…"
  open "$POUR_TARGET_APP"
  printf '\nAllow Microphone access, then enable Pour in:\n'
  printf 'System Settings → Privacy & Security → Accessibility\n'
  printf "Return to Pour's menu bar item and choose Retry Setup.\n"
fi
