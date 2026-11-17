# mCopy 3.3.1

- Bring transfer status to the foreground on the active desktop, including after background startup or minimizing the window.
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

The app is ad-hoc signed, not Apple-notarized. macOS may request approval for running the app, Finder integration, login startup, or protected locations. Permissions may need approval again after signature-changing updates or a clean uninstall. Physical disconnect/power-loss tests and execution on Intel hardware are not claimed.
