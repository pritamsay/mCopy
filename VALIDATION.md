# Validation

## 3.2.0 status and permission update

57 tests passed before publishing, including byte-weighted progress, concurrent copy/verification ordering, final completion only after verified move cleanup, and empty-folder/skipped-file completion. Both universal architectures built successfully.

The packaged `--ui-self-test` displayed the real status window during a generated 32 MiB move. Its percentage, processed bytes, file counts, and separate copy/verification labels were observed in the macOS UI. Destination bytes matched, originals were removed only after verification, and generated fixtures were cleaned up. This test does not touch the real queue, clipboard, permissions or login registrations.

The marked-prefix HTTP install/update/uninstall smoke test passed, including checksum rejection and unchanged fingerprints for the real installation and user data. The connected SMB test also passed copy, move, replacement and interrupted-replacement recovery with generated files only.

Permission setup explains the system-owned approval once and can reopen System Settings. It does not grant or claim Full Disk Access. mCopy's selection now travels over a named pasteboard rather than reading general-clipboard contents. Permission retention after an ad-hoc signature changes is not guaranteed.

The GitHub release was installed on the original Mac only after its existing transfer queue became empty. Actual Finder Copy → Paste to Folder and Cut → Paste to Folder both showed verified completion through the installed app, without clipboard permission alerts. The setup explanation was displayed and existing permissions were retained for these generated-file tests. Patch 3.2.1 also settles the progress indicator when idle or stopped.

## Transfer and recovery suite

54 tests passed on Apple Silicon macOS before publishing 3.1.0. Coverage includes:

- Copy/move, nested and empty folders, duplicate conflicts, same-folder naming, and directory merge.
- Corrupt partials, source/destination mutation, interruption/restart, and cancellation.
- Persistent queues, journal locking, merged concurrent updates, and a synchronization test proving next-file copying overlaps verification.
- NAS busy/backoff/probes, remount device-number changes, timestamp refreshes, and strict content checks.
- Unsupported exclusive rename for publication, source cleanup, replacement backup, and restoration after interrupted replacement.
- Uninstall recovery retaining originals, restoring replaced destinations, and retaining unknown legacy journals.

## Finder workflow

The previous installed build was exercised through actual Finder context menus using generated files: Copy → Paste to Folder, Cut → Paste, same-folder typed rename, duplicate Replace/Rename/Skip dialog, and clipboard cleanup after move. Source/copy/moved/renamed bytes matched. No settings or progress window appeared.

## Connected NAS

Generated payload/text files and an empty folder were tested on a real mounted SMB share. Local-to-NAS copy, NAS-to-local move, Replace, and cancellation/restoration during an interrupted replacement passed. Generated remote fixtures were cleaned up. No existing NAS files were modified.

These checks exposed and fixed server-side timestamp refreshes and unsupported exclusive rename. Physical disconnect/reconnect, power loss, and large-file throughput were not tested; error and remount conditions were simulated separately.

## Distribution

The release app and Finder extension cross-compile for arm64 and x86_64 with a macOS 13 deployment target. Local tests execute on Apple Silicon; execution on Intel hardware is not claimed. Both architectures and ad-hoc code signatures are checked before packaging. No Apple Developer ID signing identity was available, so the release is not notarized.

The packaging smoke test passed using a marked temporary install prefix and a local HTTP fixture. It verified corrupt-download rejection, repeated install/uninstall, the packaged executable's actual copy/move engine, legacy cleanup, and unchanged fingerprints for the real installed executable and user data. Login/Finder registrations were not changed by this isolated test.

The actual public GitHub raw-script and Release-asset URLs also passed isolated download/install, packaged copy/move, and uninstall checks. GitHub Actions passed all tests, both architecture builds, shell validation, signatures, and release packaging.

Live uninstall successfully stopped the old app, disabled its login item, unregistered Finder integration, and removed the installed bundle and ordinary user data. macOS protected the sandbox container metadata from command-line removal. After the Mac was unlocked, that remaining folder was moved to Bin through Finder. The published uninstall command then completed with exit code 0, and the installation/data paths were verified absent. The uninstaller reports protected-path failures with permission/Finder instructions instead of claiming those remnants were deleted.
