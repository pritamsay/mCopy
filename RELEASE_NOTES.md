# mCopy 3.4.0

- Remove the two-file pipeline gate: a slow verifier no longer stops the copier from processing the rest of the batch.
- Show when copying has finished and remaining checksum work is still running. Move originals are deleted only after their own verification succeeds.
- Keep active status above other windows, with user-controlled minimizing. A live Dock progress bar and percentage remain visible while minimized.
- Enable dynamic internet priority for NAS transfers: idle internet leaves NAS unrestricted; other Wi-Fi traffic reduces a shared copy/verification/publication budget. Passive counters replace fixed speed caps; the status checkbox can disable it.

- Bring transfer status to the foreground on the active desktop after background startup. Respect the user's minimize choice across queued transfers.
- Assign AppKit's native submenu-opening action to the mCopy parent menu item.
- Use a compact 420×230 status window with live transfer speed, Pause/Resume and Cancel.
- Measure speed from newly written bytes, including NAS publication writes; skipped files and saved-prefix checks do not inflate throughput.

- Automatic copy/move status window with progress, bytes, file counts, concurrent verification, and NAS waiting messages.
- Progress is weighted by bytes and remains monotonic while the next file copies. Completion reaches 100% only after verification finishes.
- Pause and Resume suspend both copying and verification. Cancel works safely while paused.
- Finder's submenu contains only Copy, Cut, Paste, and Paste to Folder as applicable. The status window appears automatically; its context-menu command has been removed.
- The installer requests network-volume access from the installed app when a NAS is mounted. Click the native macOS Allow button once; no custom Full Disk Access onboarding is shown.
- A private named pasteboard shares only mCopy selections, avoiding general-clipboard content reads and their repeated access prompts.
- Existing GitHub install/uninstall commands, universal binaries, automatic startup, NAS recovery, and checksum-before-delete move behavior are retained.
- Idle and stopped status windows show a settled progress bar rather than a busy spinner.

Internet priority provides best-effort Wi-Fi headroom on this Mac; router-wide QoS or guaranteed internet throughput is not claimed. The app is ad-hoc signed, not Apple-notarized. macOS may request approval for running the app, Finder integration, login startup, or protected locations. Permissions may need approval again after signature-changing updates or a clean uninstall. Physical disconnect/power-loss tests and execution on Intel hardware are not claimed.
