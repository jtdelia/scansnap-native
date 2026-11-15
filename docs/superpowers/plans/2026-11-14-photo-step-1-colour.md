# Plan: photo step 1, colour correction and the two photo scan profiles

Issue: `yomi-mj7.1`. Design: [photo scanning](../specs/2026-11-14-photo-scanning-design.md), sections Colour and Scan profiles and settings. ADR: [0001](../../adr/0001-convert-photos-with-the-scanners-colour-profile.md).

Branch from `main`: `feat/photo-colour-correction`. One pull request, titled `feat(imaging): correct photo colour with the S1300 colour profile`. Tests use Swift Testing (`import Testing`), like `Tests/YomiKitTests/FirmwareTests.swift`.

## Outcome

- Photo pages from a scan profile with colour correction on are interpreted with `ScanSnap S1300.icm` and saved in Display P3.
- New installs get "Photos – Quick" (300 dpi) and "Photos – Keepers" (600 dpi) instead of "Photos". Existing installs keep everything and gain those two once.
- Document scan profiles produce byte-identical output to today.
- `yomi scan --photo` scans with the Keepers settings.

## Task 1: pin today's behaviour before changing anything

Write these tests first, against the unchanged code, and commit them so later tasks prove nothing moved.

1. **Saved settings fixture.** Encode `ScanProfile.defaults` with the same encoder `AppModel.save()` uses (`JSONEncoder`, `.prettyPrinted`, `.sortedKeys`), wrapped as `{"profiles": […], "buttonProfileID": …}`. Commit it as `Tests/YomiKitTests/Fixtures/settings-v1.json` and declare it as a test resource in `Package.swift`.
2. **Document output is unchanged.** Build a synthetic `ScannedPage` (a white page with dark text-like bars and a coloured patch, 300 dpi). Run `PageProcessor.process` with the processing options of each current built-in scan profile. Record a SHA-256 of each output's pixel bytes as the expected value. These must still match after task 4.

## Task 2: move saved settings into YomiKit

`AppModel.Settings` lives in `YomiApp`, which tests cannot reach.

1. Add `public struct AppSettings: Codable` to `YomiKit` (new file `Sources/YomiKit/Profiles/AppSettings.swift`) with `profiles`, `buttonProfileID`, and the new `addedPhotoProfiles: Bool`.
2. Give `AppSettings` and `ScanProfile` hand-written `init(from:)` that use `decodeIfPresent` for every field, falling back to the member's default. Keep encoding synthesized.
3. Add the fixed-ID rule as one helper used by every future field: `ScanProfile.builtInPhotoIDs` (two hard-coded UUIDs), and a decode helper that returns `true` for a missing key when the profile's ID is in that set and `false` otherwise.
4. `AppModel` uses `AppSettings` for load and save; delete `AppModel.Settings`.
5. Tests: decoding `settings-v1.json` gives the same profiles as the fixture's source, and re-encoding then decoding round-trips.

## Task 3: scan profiles

1. Add `ScanProfile.correctColor: Bool`, default `false`, decoded with the fixed-ID rule.
2. Replace the built-in "Photos" profile in `ScanProfile.defaults` with "Photos – Quick" (`quality: .fine`, 300 dpi) and "Photos – Keepers" (`quality: .excellent`, 600 dpi). Use the fixed IDs. Both use `colorMode: .color`, `sides: .duplex`, `skipBlankPages: true`, `reduceBleedThrough: false`, `autoRotate: false`, `fileFormat: .jpeg`, `compression: .low` and `correctColor: true`. Duplex lets later steps read the back; for now the back is still saved or dropped by today's blank detection. Auto-rotate stays off until face rotation exists, because text rotation misfires on photos.
3. Add `AppSettings.upgraded()`: if `addedPhotoProfiles` is false, append any of the two built-in photo profiles whose ID is not already present, then set the flag. `AppModel.load()` calls it and saves.
4. Tests:
   - A fresh install has both photo profiles and no "Photos".
   - Upgrading the fixture keeps every original profile unchanged, adds both photo profiles once, and adds nothing when run again.
   - Deleting a photo profile after the upgrade does not bring it back.
   - The old "Photos" profile decodes with `correctColor == false`.

## Task 4: colour correction in processing

1. **Find the colour profile.** Add `Sources/YomiKit/Imaging/ColorProfile.swift`, modelled on `Firmware.swift`:
   - Search `/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/ScanSnap S1300.icm`, then `~/Library/Application Support/Yomi/ColorProfiles/`.
   - `locate(in:)` takes directories for testing.
   - Load with `CGColorSpace(iccData:)`, and reject files that aren't an RGB input profile.
   - Use the same profile for the S1300i.
2. **Tag raw scans.** Change `ScannedPage.cgImage()` to `cgImage(colorSpace: CGColorSpace = sRGB)`. Keep sRGB as the default so every other caller is unchanged.
3. **Options.** Add `ProcessingOptions.colorProfile: CGColorSpace?`. `ScanProfile.processingOptions` leaves it `nil`; the caller fills it in (see task 5).
4. **The photo path in `PageProcessor.process`.** When `colorProfile` is set:
   - Build the source image with that colour space.
   - Process in a second `CIContext` whose working space is extended linear sRGB, so P3 colours aren't clipped. The existing sRGB context stays for documents.
   - Skip `balanceWhite`, the document tone curve and `cleanEdges`.
   - Render with `CGColorSpace.displayP3`.
   - When `colorProfile` is `nil`, the code path is exactly today's.
5. **Downstream.** `OrientationDetector` already keeps the image's colour space. Check that `ImageWriter` writes the P3 tag in JPEG, and that `PDFWriter` keeps it if a photo profile is set to PDF.
6. Tests:
   - Use a macOS system colour profile in place of Fujitsu's file, such as `/System/Library/ColorSync/Profiles/AdobeRGB1998.icc`. A saturated Adobe RGB green patch should come out with a Display P3 colour space and stay distinct from the sRGB-tagged result.
   - The task 1 hashes are unchanged.
   - `locate` finds a profile in a temporary folder and ignores non-RGB or broken files.

## Task 5: wiring, messages, settings and command-line tool

1. **Scanning.** In `ScannerService.runScan`, when `profile.correctColor` is true, locate the colour profile once per batch and put it in the options passed to `SheetProcessor`. `SheetProcessor` builds options from `profile.processingOptions`, so pass the colour space alongside the profile.
2. **Missing colour profile.**
   - Scan in sRGB.
   - Write `color correction skipped: color profile not found` to the log.
   - Add a note to `ScanOutcome.warning`, so the progress panel shows "Color correction was skipped: the scanner's color profile was not found."
3. **Settings.**
   - Under a new "Photos" section in `ProfileEditor`, add `Toggle("Correct colors with the scanner's color profile", isOn: $profile.correctColor)`.
   - In `ScannerSettingsView` → General, add a "Color profile" row beside "Firmware", showing the profile in use or "Not found", with "Choose…".
   - "Choose…" copies the file into `~/Library/Application Support/Yomi/ColorProfiles/`.
   - Mirror `chooseFirmware` and `AppModel.installFirmware`.
   - UI text uses American spelling ("Color"), to match the existing "Color mode".
4. **Sidebar icon.** `SettingsView.icon(for:)` shows `photo` for any scan profile with `correctColor`.
5. **Command-line tool.**
   - `yomi scan [dpi] [folder] --photo` uses the "Photos – Keepers" profile with its folder replaced.
   - Resolution is the `dpi` argument, defaulting to 600.
   - It processes sheets with `SheetProcessor` and the located colour profile, and saves with `DocumentWriter`.
   - Without `--photo`, behaviour is unchanged. Update the usage line.

## Task 6: verify and hand over

1. Run `make lint` and `make test`. Run `make app`, which also quits the old `~/Applications/ScanSnap.app` if it's running and holding the scanner.
2. The owner scans two or three prints with "Photos – Keepers" and compares them with the prints in daylight. Also scan one print with colour correction turned off, for comparison.
3. **If correction is clearly better:** done.
4. **If it's worse:**
   - Set `correctColor` to `false` in both built-in photo profiles.
   - Note in the PR that the owner may need to switch it off by hand for already-upgraded profiles.
   - Open a beads issue under `yomi-mj7` to investigate ScanSnap Manager's processing.
5. Fill in every section of `.github/pull_request_template.md`. List the commands run and what they showed, and put `yomi-mj7.1` in the body. Close the bead after merge.

## Not in this step

Cropping, rotation, HEIC, back captions, saving to Photos and auto-enhance. Photo profiles keep today's paper crop (`cropAndStraighten: true`) until the cropping step replaces it for them.
