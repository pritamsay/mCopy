# mCopy

Finder-only copy and move for macOS, with resumable transfers, background verification, and NAS recovery.

## Install

Run this in Terminal as your normal Mac user:

```sh
curl -fsSL https://raw.githubusercontent.com/pritamsay/mCopy/main/install.sh | /bin/bash
```

The command downloads the prebuilt app from this repository's latest GitHub Release, verifies SHA-256 and its code signature, installs to `~/Applications/myCopy.app`, enables the Finder extension, and registers login startup. It supports **Apple Silicon and Intel on macOS 13+**. Xcode, Swift, Git, and the GitHub CLI are not needed on the destination Mac. Run the same command to update.

macOS may require one-time approval for the Finder extension or login item in **System Settings → General → Login Items & Extensions**. The app uses an ad-hoc signature and is not Apple-notarized; macOS security policy may also require approval before running it.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/pritamsay/mCopy/main/uninstall.sh | /bin/bash
```

The command stops mCopy, recovers/cancels unfinished transfers, unregisters login startup and Finder integration, then removes the installed app, preferences, cache, sandbox container, and application data for the current user. Completed copies and your original files are retained. Older builds automatically download a verified cleanup bundle when needed.

Volumes containing unfinished transfers must be available for safe recovery. If recovery cannot identify a file safely, uninstall stops and retains its records. macOS privacy permissions can prevent Terminal from removing a protected container; the command reports such failures rather than claiming complete cleanup.

## Use

1. Right-click a file/folder → **mCopy → Copy** or **Cut**.
2. Right-click in the destination → **mCopy → Paste**.
3. Right-click a destination folder → **mCopy → Paste to Folder**.

Copy retains the original. Cut moves it and deletes the original only after the destination verifies. Pasting into the same folder asks for a new name. Other duplicate names offer Replace, Rename, and Skip. Folder Replace merges folders and keeps unrelated destination files.

There is no settings window, progress window, Dock icon, menu bar item, or keyboard interception. Only filename/conflict decisions and errors needing attention show a dialog. The app starts at login and resumes saved requests.

## Reliability

- One copy worker and one verifier overlap work, with at most two files in the pipeline.
- SHA-256 is computed while copying and checked against destination bytes before move cleanup.
- Partial copies are compared against the source before resuming.
- Transient NAS errors back off and require two successful availability probes before retrying.
- SMB timestamp refreshes are accepted only with matching checksums and stable repeat reads.
- Servers without exclusive rename use verified publication and recovery fallbacks.
- Requests and journals survive restarts at `~/Library/Application Support/mCopy/Requests/`.

Files continuously modified by other software should not be moved: ordinary SMB fallback rename/delete operations cannot provide a universal atomic conditional-operation guarantee. Symbolic links, special files, and resource-fork files are currently rejected. Permission bits and modification times are restored where supported; full Finder metadata, ACLs, and extended-attribute fidelity are not implemented. Permission errors, full disks, server failures, and corrupt data can still require attention.

## Build and test

Building requires Xcode command line tools; installing a release does not.

```sh
zsh scripts/test.sh
zsh scripts/build.sh
zsh scripts/package.sh
```

Output: `dist/myCopy.app` and `.release/mCopy-macos-universal.zip` with `SHA256SUMS`. Both the app and extension include arm64/x86_64 slices and target macOS 13.

To test the network installer in an isolated workspace prefix:

```sh
python3 -m venv .venv
.venv/bin/python scripts/packaging_smoke.py
```

The test uses a local HTTP release fixture and a marked temporary directory. It checks checksum rejection, installation/update, the packaged executable's copy/move self-test, uninstall/idempotence, and legacy cleanup. It does not change HOME or register test apps for login/Finder integration.

For a connected NAS test using generated files only:

```sh
MCOPY_NAS_PATH=/Volumes/YourShare zsh scripts/test-nas.sh
```

The real-share test covers copy, move, replacement, and rollback of an interrupted replacement. It never disconnects the share. See [VALIDATION.md](VALIDATION.md) for test coverage and limits.

Developer management commands are available through the app executable: `--status`, `--self-test`, `--stop`, `--register-login`, and `--prepare-uninstall`. GitHub Actions validates builds/tests; the manual Publish release workflow creates subsequent checked releases.
