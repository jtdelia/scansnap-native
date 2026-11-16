# Appearance and file output: design

Status: approved by the owner, 2026-11-14. Terms follow [GLOSSARY.md](../../../GLOSSARY.md). Companion project: [Photo scanning](2026-11-14-photo-scanning-design.md); this project runs after its step 1.

## Intent

Two kinds of polish the owner wants. First, the app should look like a current macOS 27 app and let the owner choose light or dark independently of the system. Second, scans should be saveable in the standard formats people expect from a scanner, named and filed the way the owner wants, rather than only as PDF or JPEG with two fixed naming schemes.

## Goals

1. **Appearance setting.** System, Light or Dark.
2. **More glass,** following Apple's macOS 27 guidance.
3. **Standard file formats:** PDF, JPEG, PNG, TIFF, multi-page TIFF and HEIC.
4. **File name patterns** built from pieces, with a live example.
5. **Subfolder patterns,** such as one folder per month.
6. **Split into files every N pages** for PDF and multi-page TIFF.

## Non-goals

- AVIF, JPEG 2000, GIF, BMP, WebP and JPEG XL. (This Mac can write the first four but they are rarely used for scans; it cannot write WebP or JPEG XL.)
- PDF/A. macOS cannot produce it reliably; it would be its own project.
- Turning the menu bar menu into a glass panel. Apple's guidelines say a menu bar extra should show a menu unless its features are too complex for one.
- Glass on content such as the settings forms. Apple's guidelines reserve glass for controls and navigation.
- Supporting macOS 26.

## Anti-goals

- A saved scan profile naming its files differently after upgrading.
- Losing saved scan profiles or app settings on upgrade.
- A name pattern that can produce an invalid file name, overwrite an existing file, or write outside the scan profile's folder.
- Glass that makes text harder to read.

## Constraints

- **Saved settings must survive.** `AppModel.load()` decodes `Settings.json` with synthesized `Codable` and silently falls back to the built-in scan profiles on any failure; the next save then overwrites the user's settings. Every new field, in `ScanProfile` and in `AppModel.Settings`, must decode from the current version's settings using a default when missing. The photo project's step 1 adds a test for this; extend it.
- **macOS 27 only.** `Package.swift` (`platforms`), the `LSMinimumSystemVersion` in `scripts/build-app.sh`, `README.md` and `AGENTS.md` all say macOS 26 today. CI's macOS jobs use `runs-on: macos-26`; they must move to GitHub's `xcode-27` runner, which runs macOS 27 with Xcode 27 (generally available since 2026-10-15).
- **What already uses glass.** The Scan Now toolbar button (`.glassProminent`), the sidebar + and − buttons (`.glass`), the scanner icon in Scanner settings, and the floating progress panel (`ProgressPanel.swift`). macOS 27 refreshes all of these automatically.
- **Formats this Mac can write** (ImageIO on macOS 27.2): PDF, JPEG, PNG, TIFF, HEIC, HEICS, AVIF, JPEG 2000, GIF, BMP, PSD, OpenEXR and several texture formats. No WebP or JPEG XL.
- **Current naming.** `ScanProfile.FileNaming` has two cases. "Date and time" names a PDF `yyyy-MM-dd HH.mm.ss.pdf` and JPEG pages `yyyy-MM-dd HH.mm.ss_001.jpg`, `_002`, …. "Name and number" names files `<prefix> <number>` with `numberDigits` digits, using one number per PDF and one per JPEG page, and advances `nextNumber` by `DocumentWriter.numbersUsed`. Name clashes get ` (2)`, ` (3)`, … from `DocumentWriter.uniqueURL`.
- Run `make lint` and `make test` before calling any step done. One pull request per step, with a conventional-commit title, linked to its beads issue.

## Decided

### Appearance

- Settings → General gets "Appearance: System, Light, Dark". Default System. It is an app-wide setting stored with the app settings, not per scan profile.
- It applies to the settings window and the progress panel. The menu bar icon always follows macOS.

### Glass

- Requires macOS 27; no fallback code for older systems.
- Scan Now, Stop, and the sidebar + and − buttons use interactive glass, which gives a small bounce when clicked.
- The progress panel's glass pieces are grouped so they blend as one surface, and its corners follow the window's curve (concentric corners).
- Each scan profile's settings page gets a glass summary bar at the top, showing its key settings and an example file name.
- Windows dim when they are not in front. (Builder's call, set during review.) This applies to the settings window only. The progress panel never takes focus, so it never dims.
- The menu bar stays a plain menu. Forms stay as they are.

### File formats

- File format choices: PDF, JPEG, PNG, TIFF (one file per page), multi-page TIFF (one file per batch, or per N pages) and HEIC.
- "Make PDF searchable" stays PDF-only.
- The compression setting applies to the lossy formats: JPEG, HEIC, and images inside PDFs. PNG and TIFF are lossless, and Settings hides compression for them.
- HEIC is the default for the built-in photo scan profiles (see the photo design). Other built-in scan profiles keep their current formats.
- (Builder's call, set during review.) When this step lands, the two built-in photo scan profiles (identified by their fixed IDs) switch from JPEG to HEIC once, only if they are still set to JPEG. A marker in the app settings stops the switch from ever running again. The old "Photos" scan profile and all other scan profiles keep their saved format.
- (Builder's call, set during review.) The document tone curve stays tied to the format as today: it is off for colour pages saved as single images (JPEG, PNG, TIFF, HEIC) and on for PDF and multi-page TIFF. PDF and JPEG behave exactly as before.

### File name patterns

- A scan profile's file name is a pattern of pieces and typed text, with a live example under it.
- Pieces: date (`2026-11-14`), time (`21.42.05`), year, month, day, scan profile name, running number, and page number.
- The running number is the scan profile's existing counter: it advances by one per file written and keeps its digits setting.
- The page number is the number, within the batch, of the first page in that file.
- If a batch writes more than one file and the pattern has neither the running number nor the page number, Yomi adds `_` and a three-digit page number. This is exactly today's "Date and time" behaviour for JPEG.
- (Builder's call, set during review.) An auto-enhance `_original` file is not a separate file for naming: it takes its enhanced file's name with `_original` added, does not advance the running number, and does not count towards "more than one file".
- The two current choices become ready-made patterns. Saved scan profiles are converted to the matching pattern on upgrade and name files exactly as before. A test proves it for both choices and for PDF and JPEG.
- Characters macOS does not allow in file names (`/` and `:`) are replaced. An empty result falls back to the date-and-time pattern. Clashes still get ` (2)`, ` (3)`, ….

### Subfolders

- An optional subfolder pattern, such as `{year}/{month}`. `/` separates folder levels here and only here.
- (Builder's call, set during review.) Subfolder patterns offer only pieces that are the same for the whole batch: date, year, month, day and scan profile name, plus typed text. The running number and page number are not offered, so a batch never spreads across folders.
- Off by default. Folders are created as needed, always inside the scan profile's folder.

### Splitting

- PDF and multi-page TIFF get "One file every N pages", where pages are saved pages after blank sides are removed. The default is all pages in one file, as today.

### Order of work

One pull request per step, under one parent beads issue:

1. Require macOS 27: `Package.swift`, `Info.plist`, CI runner, `README.md`, `AGENTS.md`.
2. Appearance setting.
3. Glass.
4. File formats: PNG, TIFF, multi-page TIFF, HEIC.
5. File name patterns, including the upgrade conversion.
6. Subfolders and splitting every N pages.

## Left to the builder

- The pattern editor's design (typed tokens, a token menu, or both) and the internal token syntax, as long as the live example is always shown.
- Whether black-and-white TIFF pages are stored as 1-bit with CCITT Group 4 compression (the usual choice for scanned documents) or as 8-bit with lossless compression.
- TIFF compression method for colour and grey pages, as long as it is lossless.
- The exact contents of the glass summary bar.
- How dimming is implemented for inactive windows.
- Where the appearance setting is applied (app-wide appearance or per window), as long as both windows follow it immediately.
