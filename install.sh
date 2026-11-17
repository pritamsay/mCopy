#!/bin/bash
set -euo pipefail

# Download prebuilt, universal release assets. No Xcode or GitHub CLI is needed.
RELEASE_BASE="${MCOPY_RELEASE_BASE_URL:-https://github.com/pritamsay/mCopy/releases/latest/download}"
ASSET_NAME="mCopy-macos-universal.zip"
APP_ID="local.pritam.mycopy"
EXTENSION_ID="local.pritam.mycopy.finder"
PREFIX="$HOME"
ISOLATED=0
if [[ -n "${MCOPY_TEST_ROOT:-}" ]]; then
    PREFIX="$(cd "$MCOPY_TEST_ROOT" && pwd -P)"
    [[ "$PREFIX" != "$HOME" && "$PREFIX" != / && -f "$PREFIX/.mcopy-test-root" ]] || { printf 'Invalid isolated test root.\n' >&2; exit 1; }
    ISOLATED=1
fi
INSTALL_ROOT="$PREFIX/Applications"
INSTALLED_APP="$INSTALL_ROOT/myCopy.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() { printf 'mCopy: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "This installer is for macOS."
[[ "$(id -u)" != 0 ]] || fail "Run this as your normal Mac user, without sudo."
[[ "$HOME" == /* && "$HOME" != / && -d "$HOME" ]] || fail "A valid user home directory is required."
MAC_VERSION="$(sw_vers -productVersion)"
[[ "${MAC_VERSION%%.*}" -ge 13 ]] || fail "macOS 13 or newer is required."
case "$(uname -m)" in arm64|x86_64) ;; *) fail "Unsupported Mac architecture." ;; esac
case "$RELEASE_BASE" in https://*|http://127.0.0.1:*) ;; *) fail "Use HTTPS for release downloads." ;; esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcopy-download.XXXXXX")"
STAGE_DIR=""
RESTORE_OLD=0
cleanup() {
    if [[ "$RESTORE_OLD" == 1 && -n "$STAGE_DIR" && -d "$STAGE_DIR/previous.app" ]]; then
        rm -rf "$INSTALLED_APP"
        mv "$STAGE_DIR/previous.app" "$INSTALLED_APP"
        if [[ "$ISOLATED" == 0 ]]; then "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true; fi
    fi
    rm -rf "$WORK_DIR"
    if [[ -n "$STAGE_DIR" ]]; then rm -rf "$STAGE_DIR"; fi
}
trap cleanup EXIT

printf 'Downloading mCopy from GitHub…\n'
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 180 \
    "$RELEASE_BASE/$ASSET_NAME" -o "$WORK_DIR/$ASSET_NAME"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
    "$RELEASE_BASE/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"
read -r EXPECTED_HASH HASH_NAME < "$WORK_DIR/SHA256SUMS"
[[ "$HASH_NAME" == "$ASSET_NAME" && "${#EXPECTED_HASH}" == 64 ]] || fail "Invalid release checksum manifest."
case "$EXPECTED_HASH" in *[!0-9a-f]*) fail "Invalid release checksum." ;; esac
ACTUAL_HASH="$(shasum -a 256 "$WORK_DIR/$ASSET_NAME")"
[[ "${ACTUAL_HASH%% *}" == "$EXPECTED_HASH" ]] || fail "The download checksum did not match. Nothing was installed."
/usr/bin/ditto -x -k "$WORK_DIR/$ASSET_NAME" "$WORK_DIR/unpacked"
DOWNLOADED_APP="$WORK_DIR/unpacked/myCopy.app"
[[ -d "$DOWNLOADED_APP" ]] || fail "The release archive does not contain myCopy.app."
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$DOWNLOADED_APP/Contents/Info.plist")" == "$APP_ID" ]] || fail "Unexpected app identifier."
[[ "$(plutil -extract MCopyManagementVersion raw -o - "$DOWNLOADED_APP/Contents/Info.plist")" == 1 ]] || fail "Unsupported release management version."
/usr/bin/codesign --verify --deep --strict "$DOWNLOADED_APP"

if [[ -e "$INSTALLED_APP" ]]; then
    [[ -d "$INSTALLED_APP" && "$(plutil -extract CFBundleIdentifier raw -o - "$INSTALLED_APP/Contents/Info.plist")" == "$APP_ID" ]] || fail "Another application already occupies $INSTALLED_APP."
fi
mkdir -p "$INSTALL_ROOT"
STAGE_DIR="$(mktemp -d "$INSTALL_ROOT/.mcopy-install.XXXXXX")"
/usr/bin/ditto "$DOWNLOADED_APP" "$STAGE_DIR/myCopy.app"
if [[ "$ISOLATED" == 0 ]]; then "$STAGE_DIR/myCopy.app/Contents/MacOS/myCopy" --stop; fi

if [[ -d "$INSTALLED_APP" ]]; then
    BACKUP_ROOT="$PREFIX/Library/Application Support/mCopy/InstallBackups"
    mkdir -p "$BACKUP_ROOT"
    /usr/bin/ditto -c -k --keepParent "$INSTALLED_APP" "$BACKUP_ROOT/myCopy-$(date +%Y%m%d-%H%M%S).zip"
    mv "$INSTALLED_APP" "$STAGE_DIR/previous.app"
    RESTORE_OLD=1
fi
mv "$STAGE_DIR/myCopy.app" "$INSTALLED_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"
if [[ "$ISOLATED" == 0 ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP"
    /usr/bin/pluginkit -e ignore -i "$EXTENSION_ID" >/dev/null 2>&1 || true
    /usr/bin/pluginkit -a "$INSTALLED_APP/Contents/PlugIns/MyCopyFinder.appex"
    if ! /usr/bin/pluginkit -e use -i "$EXTENSION_ID"; then
        printf 'macOS needs you to enable myCopy under System Settings → Login Items & Extensions → Finder.\n'
    fi
    if ! "$INSTALLED_APP/Contents/MacOS/myCopy" --register-login; then
        printf 'Enable myCopy in System Settings → Login Items to start it automatically.\n'
    fi
    /usr/bin/open -gj "$INSTALLED_APP" --args --setup-network-access
fi
RESTORE_OLD=0
printf 'Installed mCopy at %s\nUse Finder → right-click → mCopy.\n' "$INSTALLED_APP"
if [[ "$ISOLATED" == 0 ]]; then
    printf 'If a NAS is mounted, macOS may now show its network-volume prompt. Click Allow once.\nIf no NAS is mounted, this prompt appears with your first NAS transfer.\n'
fi
