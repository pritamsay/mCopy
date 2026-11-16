#!/bin/bash
set -euo pipefail

APP_ID="local.pritam.mycopy"
EXTENSION_ID="local.pritam.mycopy.finder"
PREFIX="$HOME"
ISOLATED=0
if [[ -n "${MCOPY_TEST_ROOT:-}" ]]; then
    PREFIX="$(cd "$MCOPY_TEST_ROOT" && pwd -P)"
    [[ "$PREFIX" != "$HOME" && "$PREFIX" != / && -f "$PREFIX/.mcopy-test-root" ]] || { printf 'Invalid isolated test root.\n' >&2; exit 1; }
    ISOLATED=1
fi
INSTALLED_APP="$PREFIX/Applications/myCopy.app"
LIBRARY="$PREFIX/Library"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
WORK_DIR=""
RESTORE_LEGACY=0

fail() { printf 'mCopy: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ "$RESTORE_LEGACY" == 1 && -n "$WORK_DIR" && -d "$WORK_DIR/previous.app" ]]; then
        rm -rf "$INSTALLED_APP"
        mv "$WORK_DIR/previous.app" "$INSTALLED_APP"
    fi
    if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT
[[ "$(uname -s)" == Darwin ]] || fail "This uninstaller is for macOS."
[[ "$(id -u)" != 0 ]] || fail "Run this as your normal Mac user, without sudo."
[[ "$HOME" == /* && "$HOME" != / && -d "$HOME" ]] || fail "A valid user home directory is required."

if [[ -e "$INSTALLED_APP" ]]; then
    [[ -d "$INSTALLED_APP" && "$(plutil -extract CFBundleIdentifier raw -o - "$INSTALLED_APP/Contents/Info.plist")" == "$APP_ID" ]] || fail "The app at $INSTALLED_APP has a different identifier; it was not removed."
    MANAGEMENT_VERSION="$(plutil -extract MCopyManagementVersion raw -o - "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$MANAGEMENT_VERSION" != 1 ]]; then
        # Old builds lack the command that unregisters their own login item.
        # Temporarily use the verified current management bundle at the same
        # installed URL. It never launches/registers; it only performs cleanup.
        RELEASE_BASE="${MCOPY_RELEASE_BASE_URL:-https://github.com/pritamsay/mCopy/releases/latest/download}"
        case "$RELEASE_BASE" in https://*|http://127.0.0.1:*) ;; *) fail "Use HTTPS for release downloads." ;; esac
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcopy-uninstall.XXXXXX")"
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 180 \
            "$RELEASE_BASE/mCopy-macos-universal.zip" -o "$WORK_DIR/app.zip"
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
            "$RELEASE_BASE/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"
        read -r EXPECTED_HASH HASH_NAME < "$WORK_DIR/SHA256SUMS"
        [[ "$HASH_NAME" == mCopy-macos-universal.zip && "${#EXPECTED_HASH}" == 64 ]] || fail "Invalid release checksum manifest."
        case "$EXPECTED_HASH" in *[!0-9a-f]*) fail "Invalid release checksum." ;; esac
        ACTUAL_HASH="$(shasum -a 256 "$WORK_DIR/app.zip")"
        [[ "${ACTUAL_HASH%% *}" == "$EXPECTED_HASH" ]] || fail "The cleanup helper download checksum did not match."
        /usr/bin/ditto -x -k "$WORK_DIR/app.zip" "$WORK_DIR/unpacked"
        HELPER_APP="$WORK_DIR/unpacked/myCopy.app"
        [[ "$(plutil -extract CFBundleIdentifier raw -o - "$HELPER_APP/Contents/Info.plist")" == "$APP_ID" ]] || fail "Unexpected cleanup helper identifier."
        [[ "$(plutil -extract MCopyManagementVersion raw -o - "$HELPER_APP/Contents/Info.plist")" == 1 ]] || fail "Unsupported cleanup helper."
        /usr/bin/codesign --verify --deep --strict "$HELPER_APP"
        if [[ "$ISOLATED" == 0 ]]; then "$HELPER_APP/Contents/MacOS/myCopy" --stop; fi
        mv "$INSTALLED_APP" "$WORK_DIR/previous.app"
        RESTORE_LEGACY=1
        /usr/bin/ditto "$HELPER_APP" "$INSTALLED_APP"
    fi
    if [[ "$ISOLATED" == 1 ]]; then
        "$INSTALLED_APP/Contents/MacOS/myCopy" --prepare-test-uninstall "$PREFIX"
    else
        "$INSTALLED_APP/Contents/MacOS/myCopy" --prepare-uninstall
    fi
    RESTORE_LEGACY=0
else
    REQUEST_ROOT="$LIBRARY/Application Support/mCopy/Requests"
    if [[ -f "$LIBRARY/Application Support/Mover/transfer.json" ]] ||
       { [[ -d "$REQUEST_ROOT" ]] && [[ -n "$(find "$REQUEST_ROOT" -maxdepth 2 -name '*.json' -print -quit)" ]]; }; then
        fail "Saved transfer records remain. Reinstall mCopy first so its recovery files can be cleaned up safely."
    fi
fi

if [[ "$ISOLATED" == 0 ]]; then
    /usr/bin/pluginkit -e ignore -i "$EXTENSION_ID" >/dev/null 2>&1 || true
    EXTENSION_PATH="$INSTALLED_APP/Contents/PlugIns/MyCopyFinder.appex"
    if [[ -d "$EXTENSION_PATH" ]]; then /usr/bin/pluginkit -r "$EXTENSION_PATH" >/dev/null 2>&1 || true; fi
    for MCOPY_PID in $(/usr/bin/pgrep -x MyCopyFinder || true); do
        PROCESS_PATH="$(/bin/ps -p "$MCOPY_PID" -o comm= 2>/dev/null || true)"
        if [[ "$PROCESS_PATH" == "$EXTENSION_PATH/Contents/MacOS/MyCopyFinder" ]]; then
            /bin/kill -TERM "$MCOPY_PID" 2>/dev/null || true
        fi
    done
    if [[ -d "$INSTALLED_APP" ]]; then "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true; fi
    for DOMAIN in "$APP_ID" "$EXTENSION_ID"; do
        if /usr/bin/defaults read "$DOMAIN" >/dev/null 2>&1; then /usr/bin/defaults delete "$DOMAIN"; fi
    done
fi

# Clear the known legacy lock even if macOS later protects container metadata.
rm -f "$LIBRARY/Application Support/Mover/transfer.json.lock"
rmdir "$LIBRARY/Application Support/Mover" 2>/dev/null || true

REMOVAL_FAILED=0
rm -rf "$INSTALLED_APP" \
    "$LIBRARY/Application Support/mCopy" \
    "$LIBRARY/Preferences/$APP_ID.plist" "$LIBRARY/Preferences/$EXTENSION_ID.plist" \
    "$LIBRARY/Caches/$APP_ID" "$LIBRARY/Caches/$EXTENSION_ID" \
    "$LIBRARY/Saved Application State/$APP_ID.savedState" \
    "$LIBRARY/Saved Application State/$EXTENSION_ID.savedState" \
    "$LIBRARY/Containers/$APP_ID" "$LIBRARY/Containers/$EXTENSION_ID" \
    "$LIBRARY/Application Scripts/$APP_ID" "$LIBRARY/Application Scripts/$EXTENSION_ID" \
    "$LIBRARY/HTTPStorages/$APP_ID" "$LIBRARY/Logs/myCopy" || REMOVAL_FAILED=1
if [[ "$REMOVAL_FAILED" == 1 ]]; then
    printf '\nmacOS protected one or more paths listed above. The app and its login/Finder registrations have been removed.\n' >&2
    printf 'To finish removing protected sandbox metadata, remove that container in Finder, or grant your terminal Full Disk Access, then rerun this command.\n' >&2
    exit 1
fi
printf 'mCopy uninstalled. Completed copies and your original files were retained.\n'
