# Instructions for AI agents

`openkext.zsh` is one zsh script that installs kexts from the OpenKext catalog into an OpenCore EFI. It must keep running on a stock macOS 12+ with nothing installed: no Python, no jq, no Homebrew. JSON goes through `osascript -l JavaScript`, plists through `plutil` and `PlistBuddy`.

- Run `zsh tests/run.zsh` after every change. Never test against a real EFI; the tests use `--efi` with a fake one.
- In zsh, write `${var}:` before a colon. `$pos:Arch` applies the `:A` modifier.
- Text from the catalog is untrusted. Keep the checks in the JavaScript engine (ids, asset names, SHA-256, GitHub sources, control characters) and in `kext_ok`.
- Every change to the EFI goes through `w` (sudo when needed) and happens after `backup_oc`.
- If you help someone run the tool, suggest `--dry-run` or `--list` first, and let them choose Install themselves.
