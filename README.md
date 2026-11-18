# Yomi

The ScanSnap S1300 lives again.

Yomi is a native Apple Silicon driver and menu-bar app for the Fujitsu ScanSnap S1300 and S1300i
document scanners, for people who want to keep using these scanners on modern macOS
without the Intel-only ScanSnap Manager and Rosetta.

The name comes from *yomigaeru* (甦る), "to come back to life", which literally means
"to return from Yomi", the Japanese land of the dead. *Yomi* (読み) also means "reading".

It talks to the scanner directly over USB from user space (IOKit and IOUSBHost), so there
is no kernel extension, no DriverKit extension, and no admin install.

> This project is not affiliated with, endorsed by, or supported by Fujitsu or PFU.
> ScanSnap is a trademark of PFU Limited.

## Requirements

- macOS 27 or later on Apple Silicon
- Xcode 27 or later (Swift 6 toolchain)
- A ScanSnap S1300 or S1300i
- The scanner's firmware file, from your own copy of ScanSnap Manager (see below)

### Firmware

The S1300 has no usable firmware when it powers on; the host uploads it every time. The
firmware is copyrighted by the vendor and is **not** included in this repository. The app
looks for it in:

1. `/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/Firmware`
2. `~/Library/Application Support/Yomi/Firmware`

Files are named `1300_XXXX.nal` (S1300) or `1300i_XXXX.nal` (S1300i). If ScanSnap Manager
is installed, nothing else is needed. Otherwise, copy the file into the second folder, or
choose it in the app's Settings window.

## Quick start

```sh
git clone https://github.com/jtdelia/yomi.git
cd yomi
make app
```

`make app` builds `Yomi.app`, signs it ad hoc, and installs it in `~/Applications`.
Open it, plug in the scanner, and press the scan button. PDFs are saved to
`~/Documents/Yomi` by default.

## Usage

The app lives in the menu bar. Pressing the scanner's button scans with the selected
profile; the Settings window manages profiles (resolution, color mode, page size, blank
page removal, output folder).

In Recent Scans, renaming a scan gives its PDF and sidecars the same stem. If any
name is taken, Yomi tries the next suffix for the whole group. On APFS, each new
name appears with the complete file. On exFAT, other apps can see the new files
while Yomi copies them. A failed copy can leave an empty or incomplete file at the
path in the error message. Yomi keeps the originals until the copies are complete
and the new names are saved in history. An interruption can leave both sets of names.
If a file changes during cleanup, check the paths in the error message before retrying.

The `yomi` command-line tool drives the same code without the app:

```sh
swift run yomi info                # find the scanner and print its identity
swift run yomi firmware            # upload firmware
swift run yomi scan 300 ~/Desktop  # scan the loaded sheets at 300 dpi to a PDF
swift run yomi scan ~/Desktop --photo  # scan prints with the "Photos – Keepers" settings (600 dpi unless given)
```

Logs are written to `~/Library/Logs/Yomi.log`.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/YomiKit` | USB transport, scanner protocol, calibration, image processing, PDF output |
| `Sources/YomiApp` | The menu-bar app (AppKit and SwiftUI) |
| `Sources/yomi` | Command-line tool for scanning and debugging |
| `scripts/` | App bundle build, icon generator, and the table generator for `S300Tables.swift` |

## Development

| Command      | What it does                                         |
| ------------ | ---------------------------------------------------- |
| `make lint`  | Build with warnings as errors and check the scripts  |
| `make test`  | Run the tests                                        |
| `make build` | Release build                                        |
| `make app`   | Build and install `Yomi.app` in `~/Applications` |
| `make check` | Lint, test, and build                                |

CI runs `make lint`, `make test`, and `make build` on every pull request.

## Acknowledgements

The per-resolution scan and calibration parameters in
`Sources/YomiKit/Protocol/S300Tables.swift` are generated from the
[SANE](http://www.sane-project.org/) `epjitsu` backend by `scripts/gen_s300_tables.py`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately, as described
in [SECURITY.md](SECURITY.md).

## License

[GPL-2.0-or-later](LICENSE), because the scan tables are derived from SANE, which uses
the same license.
