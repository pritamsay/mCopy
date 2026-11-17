# Validation

## 3.4.0 independent verification, Dock and internet priority

74 tests passed before publication. A six-file regression holds the first verifier until the entire copy phase has finished, proving that verification no longer blocks the rest of the batch. A second test cancels with a full verification backlog and confirms that unverified originals survive recovery.

Internet-priority tests cover passive CSV parsing without double-counting process summaries, initial cumulative-counter rejection, IPv6, reordered/malformed rows, idle unrestricted operation, lower NAS budgets as other traffic increases, observed-capacity-dependent budgets, no Wi-Fi budget for wired/local transfers, shared copy/verification tokens, rate changes and prompt cancellation of a bandwidth wait. The packaged passive monitoring self-test parsed live Wi-Fi counters on the original Mac without a speed test or saved endpoints. Internet throughput under controlled competing load and router-wide QoS are not claimed.

Both universal architecture slices and code signatures passed. The isolated HTTP installation/update/uninstall smoke test passed, including unchanged fingerprints for the actual installed app and user data. Generated-file copy, move, Replace and interrupted replacement recovery passed on the mounted SMB share; generated fixtures were removed.

The packaged interactive UI test confirmed a 420×230 window automatically visible at floating level on the active Space after hidden startup, before computer control activated it. The compact layout, speed field, Internet priority checkbox and Pause/Cancel controls were inspected. Clicking the native Minimize button kept the status minimized across a simulated next request while the application's Dock content view and progress continued updating. The verified move then completed. Dock progress was checked through the app's live Dock view state; direct inspection of the Dock application is not claimed.

The public v3.4.0 release was downloaded through the README install command only after the actual request queue was empty. The installed executable matched the tested build; version 3.4.0/build 17, login startup and its sole Finder extension were verified. Actual Finder submenu clicks stayed open for both Copy and Paste. A generated 8 MiB Finder-to-NAS copy retained its original and matched destination bytes. Before computer control opened mCopy, its status reported active and non-hidden, confirming automatic foreground presentation. The installed 100% completion window included the enabled Internet priority checkbox. Generated fixtures were removed. GitHub Actions run 44161891232 passed tests, shell checks, both architectures, signatures, packaging and isolated install/uninstall.

## 3.3.1 visibility and submenu follow-up

64 tests passed before publication. The menu wrapper now uses AppKit's `setSubmenu(_:for:)`, which assigns `submenuAction:` instead of leaving the parent action nil. The regression test verifies that action and the linked submenu. Speed tests cover stalls, pause/reset and counter resets; real transfer tests confirm skipped files and old partial prefixes do not count as newly written bytes.

The packaged UI self-test deliberately hides and minimizes its own app/window after launch, then starts a generated transfer. It checks visibility, non-minimized state, non-hidden app state, the active Space and exact 420×230 content size before any computer-control inspection activates the app. This check and the verified move passed. The compact layout was inspected with long paths and a live 3.8 MB/s speed display. The isolated HTTP installation/update/removal test also passed with the actual installation and data unchanged.

The GitHub candidate was then installed on the original Mac with an empty transfer queue. Clicking the mCopy parent on both a generated file and destination folder kept its submenu open. Copy → Paste to Folder copied only the generated fixture and retained its original. Before opening the app through computer control, its read-only status reported `active: true` and `hidden: false`, confirming automatic foreground activation. The installed compact completion window was inspected afterward. No existing user/NAS files were changed by this check.

## 3.3.0 automatic status and network approval

60 tests passed before publication, including Pause/Resume during copying, Pause/Resume during verification with move originals retained, and safe cancellation/recovery while suspended. Existing conflict tests still cover Replace, Rename, Skip and same-folder renaming.

The packaged status window was exercised on generated files: Pause changed to Resume, verification stayed at 88% while paused, and Resume completed the verified move at 100%. Root and submenu source checks confirm there is no transfer-status context command. Universal builds, isolated HTTP install/update/uninstall and real SMB copy/move/replacement/recovery tests passed.

The installer now launches the installed app with `--setup-network-access`. It requests a read-only listing of one mounted network-volume root to trigger macOS's native approval, without touching NAS file contents or privacy settings. If no NAS is mounted, the first transfer requests access normally. A permission already allowed by macOS is not reset to manufacture another prompt. Ad-hoc signing cannot guarantee that approval survives later signature-changing updates.

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
