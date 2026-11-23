# openkext

A command-line tool that finds the drivers in the [OpenKext catalog](https://openkext.org) that fit your hackintosh, then downloads, checks and installs them into your OpenCore EFI. It runs in Terminal with a full-screen menu, starts with the recommended drivers already selected, and asks before it changes anything.

```sh
zsh -c "$(curl -fsSL https://openkext.org/install)"
```

To see what it would do without touching the EFI:

```sh
zsh -c "$(curl -fsSL https://openkext.org/install)" openkext --dry-run
```

## What it does

1. Reads the PCI and USB ids of your hardware (`ioreg`), the macOS version, the OpenCore version, and the kexts already in your EFI.
2. Downloads the catalog and matches it against your hardware. A driver is **recommended** (★, selected from the start) when it matches a device you have, was tested on your macOS version, has a build for it, and is `author-tested` or `community-verified`. Drivers with no test reports yet, or reported as broken, are shown but never preselected.
3. Lets you change the selection, and pick which release files to install (→ on a driver).
4. Shows a review screen with every file, its SHA-256, and any warnings. You choose **Install**, **Dry run**, **Back** or **Quit**.
5. On install: copies `EFI/OC` to `~/Library/Application Support/OpenKext/backups/<date>`, downloads each file from the project's GitHub release, refuses it if the SHA-256 differs from the catalog, copies the kexts into `EFI/OC/Kexts`, and adds or updates their `Kernel > Add` entries in `config.plist`. A kext that is already installed under any folder name (same bundle id) is replaced in place. A new kext goes before any kext that depends on it. The edited `config.plist` is checked with `plutil -lint` before it is written; if the check fails, the backup is put back.

Afterwards it tells you about dependencies that are missing from your EFI, and links to the page where you can report how the driver worked.

## Keys

| Key | Action |
|---|---|
| ↑ ↓ or j k | move |
| space | select or unselect |
| → | choose which files of a driver to install |
| a | show the whole catalog, or only what matches |
| enter | continue |
| q | quit without changing anything |

## Options

```
--dry-run     download and check everything, change nothing (writes the config it would use to the state folder)
--list        print what matches this machine and exit; does not mount the EFI
--yes         install the recommended drivers without the menu
--all         include drivers that do not match your hardware
--efi PATH    use this EFI volume, e.g. /Volumes/EFI, instead of finding it
--restore     put back an EFI/OC backup made by an earlier run
```

## Requirements and limits

- macOS 12 or later on an Intel or AMD PC booted with OpenCore. It refuses to run on Apple Silicon, and asks for `--efi` when OpenCore is not detected.
- Nothing to install: it uses zsh, curl, shasum, ditto, plutil, PlistBuddy, ioreg, diskutil, nvram and osascript, which ship with macOS.
- It asks for your password (through `sudo`) only to mount the EFI partition and to write to it.
- It does not edit ACPI, quirks, NVRAM or SMBIOS, and it does not install kexts that are not in the catalog.
- Keep a bootable USB with a working EFI anyway. If the machine does not boot after an install, start from the USB and run `openkext --restore`, or copy the backup folder back to `EFI/OC`.

## Trust

The catalog is community-run. The bot accepts entries that pass fixed rules, and status comes from test reports; read [GOVERNANCE](https://openkext.org/docs/governance/). The tool checks every download against the SHA-256 in the catalog, accepts only `https://github.com/<owner>/<repo>` sources, and strips control characters from catalog text before showing it.

To check the script itself before running it, download it and compare with the `openkext.zsh.sha256` file of the same [release](https://github.com/openkext/cli/releases):

```sh
curl -fsSLO https://github.com/openkext/cli/releases/latest/download/openkext.zsh
curl -fsSL https://github.com/openkext/cli/releases/latest/download/openkext.zsh.sha256 | shasum -a 256 -c
zsh openkext.zsh
```

## Development

```sh
zsh tests/run.zsh      # fake EFI, local catalog and fake ioreg output; touches nothing on the machine
```

Environment variables used by the tests: `OPENKEXT_API`, `OPENKEXT_ASSET_BASE`, `OPENKEXT_STATE`, `OPENKEXT_MACOS`, `OPENKEXT_ARCH`, `OPENKEXT_OCVER`, `OPENKEXT_IOREG_PCI`, `OPENKEXT_IOREG_USB`, `OPENKEXT_KMUTIL`, `OPENKEXT_KEYS` (a file of keystrokes for the menu) and `OPENKEXT_NO_SUDO`.

A release is a tag `vX.Y.Z`; CI attaches `openkext.zsh` and its SHA-256, and the site serves the newest release at https://openkext.org/install.

Developed with Claude (Opus 5.5). MIT license.
