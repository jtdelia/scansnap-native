# ScanSnap Native

A native Apple Silicon driver and menu-bar app for the Fujitsu ScanSnap S1300 and S1300i
document scanners, for people who want to keep using these scanners on modern macOS
without the Intel-only ScanSnap Manager and Rosetta.

It talks to the scanner directly over USB from user space (IOKit and IOUSBHost), so there
is no kernel extension, no DriverKit extension, and no admin install.

> This project is not affiliated with, endorsed by, or supported by Fujitsu or PFU.
> ScanSnap is a trademark of PFU Limited.

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 26 or later (Swift 6 toolchain)
- A ScanSnap S1300 or S1300i
- The scanner's firmware file, from your own copy of ScanSnap Manager (see below)

### Firmware

The S1300 has no usable firmware when it powers on; the host uploads it every time. The
firmware is copyrighted by the vendor and is **not** included in this repository. The app
looks for it in:

1. `/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/Firmware`
2. `~/Library/Application Support/ScanSnapNative/Firmware`

Files are named `1300_XXXX.nal` (S1300) or `1300i_XXXX.nal` (S1300i). If ScanSnap Manager
is installed, nothing else is needed. Otherwise, copy the file into the second folder, or
choose it in the app's Settings window.

## Quick start

```sh
git clone https://github.com/jtdelia/scansnap-native.git
cd scansnap-native
make app
```

`make app` builds `ScanSnap.app`, signs it ad hoc, and installs it in `~/Applications`.
Open it, plug in the scanner, and press the scan button. PDFs are saved to
`~/Documents/ScanSnap` by default.

## Usage

The app lives in the menu bar. Pressing the scanner's button scans with the selected
profile; the Settings window manages profiles (resolution, color mode, page size, blank
page removal, output folder).

The `sscan` command-line tool drives the same code without the app:

```sh
swift run sscan info              # find the scanner and print its identity
swift run sscan firmware          # upload firmware
swift run sscan scan 300 ~/Desktop  # scan the loaded sheets at 300 dpi to a PDF
```

Logs are written to `~/Library/Logs/ScanSnap.log`.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/ScanSnapKit` | USB transport, scanner protocol, calibration, image processing, PDF output |
| `Sources/ScanSnapNative` | The menu-bar app (AppKit and SwiftUI) |
| `Sources/sscan` | Command-line tool for scanning and debugging |
| `scripts/` | App bundle build, icon generator, and the table generator for `S300Tables.swift` |

## Development

| Command      | What it does                                         |
| ------------ | ---------------------------------------------------- |
| `make lint`  | Build with warnings as errors and check the scripts  |
| `make test`  | Run the tests                                        |
| `make build` | Release build                                        |
| `make app`   | Build and install `ScanSnap.app` in `~/Applications` |
| `make check` | Lint, test, and build                                |

CI runs `make lint`, `make test`, and `make build` on every pull request.

## Acknowledgements

The per-resolution scan and calibration parameters in
`Sources/ScanSnapKit/Protocol/S300Tables.swift` are generated from the
[SANE](http://www.sane-project.org/) `epjitsu` backend by `scripts/gen_s300_tables.py`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately, as described
in [SECURITY.md](SECURITY.md).

## License

[GPL-2.0-or-later](LICENSE), because the scan tables are derived from SANE, which uses
the same license.
