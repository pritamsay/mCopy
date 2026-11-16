# mCopy 3.2.1

- Automatic copy/move status window with progress, bytes, file counts, concurrent verification, and NAS waiting messages.
- Progress is weighted by bytes and remains monotonic while the next file copies. Completion reaches 100% only after verification finishes.
- Hide the window without stopping work; reopen from Finder's Show Transfer Status menu. Cancel safely with confirmation.
- One-time file-access setup instructions, with a Permissions button to reopen them. macOS owns the actual access approvals.
- A private named pasteboard shares only mCopy selections, avoiding general-clipboard content reads and their repeated access prompts.
- Existing GitHub install/uninstall commands, universal binaries, automatic startup, NAS recovery, and checksum-before-delete move behavior are retained.
- Idle and stopped status windows show a settled progress bar rather than a busy spinner.

The app is ad-hoc signed, not Apple-notarized. macOS may request approval for running the app, Finder integration, login startup, or protected locations. Permissions may need approval again after signature-changing updates or a clean uninstall. Physical disconnect/power-loss tests and execution on Intel hardware are not claimed.
