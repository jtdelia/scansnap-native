# Photo scanning: design

Status: approved by the owner, 2026-11-14. Terms follow [GLOSSARY.md](../../../GLOSSARY.md). Companion project: [Appearance and file output](2026-11-14-appearance-and-file-output-design.md).

## Intent

The owner is digitising a family collection of old prints on an S1300 by feeding them straight through, with no carrier sheet. Today Yomi treats prints like documents: colours are tagged as plain sRGB, white balance and edge clean-up built for paper alter them, cropping fails on dark prints, rotation only reads text, and anything written on the back is lost or saved as a separate, unpaired image. The goal is that a pile of prints comes out as upright, well-coloured photos in Apple Photos, with the writing on the back searchable, without the owner touching each one.

Accurate colour is the most valuable part. The rest serve one workflow: feed a stack, get finished photos.

## Goals

1. **Accurate colour.** Photos are corrected with the S1300 colour profile and saved in Display P3.
2. **Two photo scan profiles.** "Photos – Quick" (300 dpi) for large batches and "Photos – Keepers" (600 dpi), identical apart from resolution.
3. **Photo cropping.** Crop tightly to the print's own edges, never snapping to paper sizes, including dark prints and small or odd sizes (wallet, 3.5×5, 4×6, 5×7).
4. **Face-based rotation.** Prints come out upright.
5. **Back captions.** Writing on a print's back becomes the photo's caption.
6. **Save to Apple Photos.** Into a chosen album, as well as or instead of a folder.
7. **Auto-enhance.** Apple's auto-adjust is applied, with the untouched original always recoverable.

HEIC output, originally part of this list, moved to the companion project with the other file formats. Photo scan profiles use HEIC once that lands, and JPEG until then.

## Non-goals

- Document scan profiles do not change. Colour correction, photo cropping, face rotation, back captions and auto-enhance are off for them, and their output must be byte-for-byte what it is today for the same input.
- Setting a photo's date from a date written on the back.
- Saving an image of the back of a print (see [ADR 0002](../../adr/0002-back-captions-replace-back-images.md)).
- Carrier sheet support.
- Saving to Photos from the `yomi` command-line tool.
- Colour-correcting documents.
- Reverse-engineering ScanSnap Manager's colour processing (a separate issue if step 1's check fails; see Colour).

## Anti-goals

These would make the work a failure even if every feature technically works:

- Losing a user's saved scan profiles on upgrade.
- An enhanced photo whose original cannot be recovered.
- Losing a picture because its print went in back-side-first.
- Losing a batch because saving to Photos failed.
- A print rotated wrongly with confidence: leaving it as fed is better than guessing.
- Brand printing or lab printing on photo paper turned into captions.
- Committing the colour profile, or any other Fujitsu file, to the repository.

## Constraints

- **Vendor files.** `ScanSnap S1300.icm` is Fujitsu's and must never be committed (see `AGENTS.md`). On this machine it is at `/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/ScanSnap S1300.icm`. It is an ICC v2 scanner input profile (class `scnr`, RGB to XYZ, with full A2B lookup tables, 650 KB). Tests must use a profile that ships with macOS instead.
- **Saved settings must survive.** `AppModel.load()` decodes `Settings.json` with synthesized `Codable`; if decoding fails it silently falls back to `ScanProfile.defaults`, and the next save overwrites the user's profiles. Every new `ScanProfile` field must decode from settings saved by the current version, using its default when the key is missing. Add a test that decodes a settings file from the current version.
- **Photos access needs the app.** PhotoKit permission prompts need an app bundle and a usage description in `Info.plist` (written by `scripts/build-app.sh`). Choosing or creating an album needs full read/write library access, not add-only. The app is signed ad hoc, so macOS may ask for permission again after rebuilding.
- **No side-by-side reference.** ScanSnap Manager crashes on the current macOS, and no old ScanSnap Manager photo scans exist, so colour cannot be compared against Fujitsu's own output.
- **Calibration differs.** Fujitsu built the colour profile against ScanSnap Manager's calibration; Yomi calibrates as SANE's `epjitsu` does. The profile should bring colours much closer but is not guaranteed to match exactly.
- **Hardware.** The S1300 scans both sides of every sheet in one pass, so reading the back costs no extra scanning time. Supported resolutions are 150, 300 and 600 dpi on both USB and AC power.
- **Minimum system.** Yomi requires macOS 27 from the companion project onwards.
- Run `make lint` and `make test` before calling any step done. Each step is its own pull request with a conventional-commit title, linked to its beads issue.

## Decided

### Scan profiles and settings

- The new behaviour is made of ordinary scan profile settings, grouped under a "Photos" heading in Settings, as ScanSnap Manager grouped photo sizes with its other settings. There is no global Documents/Photos switch.
- Built-in scan profiles for new installs: "Photos – Quick" (300 dpi) and "Photos – Keepers" (600 dpi) replace the current "Photos" profile. Both have colour correction, photo cropping, face rotation, back captions, auto-enhance and saving to Photos turned on. Both scan both sides.
- Existing installs keep every saved scan profile, including the old "Photos" one, which the user can delete. The two new photo scan profiles are added once on upgrade and are not re-added if the user later deletes them.
- (Builder's call, set during review.) The two built-in photo scan profiles have fixed IDs. When a later step adds a setting, a saved scan profile without that key gets the setting on if it has one of those IDs, and off otherwise. This way the owner's Quick and Keepers profiles pick up each feature as it lands, and document scan profiles never do.
- Switching between Quick and Keepers uses the existing "Scan Button Profile" menu in the menu bar. No new controls.
- Wording: "scan profile" for saved settings, "colour profile" for the scanner's colour file, never "profile" alone in UI text.

### Colour

- The raw scan is interpreted with the S1300 colour profile and converted to Display P3 on save. The colour profile itself is not embedded ([ADR 0001](../../adr/0001-convert-photos-with-the-scanners-colour-profile.md)).
- White balance, the document tone curve and edge whitening (`cleanEdges`) are off whenever colour correction is on, because they undo it.
- Yomi looks for the colour profile first in `~/Library/Application Support/Yomi/ColorProfiles`, where Settings puts a chosen file, then in the ScanSnap Manager app, so a colour profile chosen in Settings is used even while ScanSnap Manager is installed. Settings shows which colour profile is in use and offers "Choose…", which copies the chosen file into Application Support.
- If colour correction is on but no colour profile is found, the scan still completes in sRGB, and the progress panel and log say colour correction was skipped.
- Verification is by eye: a Yomi scan on screen beside the print, in daylight. A printed colour reference card is only worth buying if that leaves doubt.
- If the check shows colours worse than without the colour profile, step 1 still ships, with colour correction off by default in the photo scan profiles, and a separate beads issue is opened to investigate what ScanSnap Manager does before applying the colour profile. Step 1 does not wait for that investigation.

### Cropping

- Photo cropping finds the print's edges against the scanner's dark backing without assuming the print is brighter than the backing, so dark prints crop correctly. It straightens small skews as today and never snaps to paper sizes.

### Rotation

- For photo scan profiles: use face detection first; if no faces are found, use the existing text-based rotation; if neither gives a clear answer, leave the print as fed. Document scan profiles keep text-based rotation only.

### Back captions

- **Which side is the picture.** Yomi decides which side of a print is the picture (colour, faces, photographic detail) and which is the back (mostly plain paper, with or without writing). When the sides are clearly the wrong way round, it swaps them. When it can't tell, it trusts the feed direction.
- The back is checked with the existing blank and show-through detection. A blank back is dropped as today.
- A back with writing is read with Apple's text recognition, with the language detected automatically. The text becomes the photo's caption and the back image is discarded.
- Brand printing (repeating maker names) and lab printing (order numbers, frame numbers, lab codes) count as blank. When a back has both handwriting and printing, only the handwriting becomes the caption. A neat printed note may occasionally be dropped as lab printing; that is accepted.
- Writing that cannot be read still counts as writing; the photo simply has no caption.
- The caption is stored inside the image file so both folder files and Photos carry it. If Photos turns out to ignore it on import, Yomi sets the caption through Photos' scripting interface instead, which asks the user once to let Yomi control Photos.
- Yomi only sets captions when it saves a scan. It never changes captions afterwards.

### Saving to Photos

- Each scan profile has a "Save to" choice: Folder, Photos, or both. The built-in photo scan profiles use Photos only.
- With Photos, the user picks an existing album or types a new name, and Yomi creates the album the first time it is needed. With no album chosen, photos go into the library only.
- If saving to Photos fails (permission denied or reset, album cannot be created, Photos unavailable), Yomi saves the batch to the scan profile's folder instead and says so in the progress panel and log. A batch is never dropped.
- Saving to Photos is in the app only. The `yomi` tool gets every other photo feature.
- (Builder's call, set during review.) The `yomi` tool gets one `--photo` flag on `scan`, which uses the "Photos – Keepers" settings except saving to Photos. Resolution keeps using the existing `scan [dpi]` argument. The tool does not read the app's saved scan profiles.

### Auto-enhance

- Uses Core Image's built-in auto-adjustment (the same adjustments as the magic-wand button in Photos).
- In Photos: one photo per print, with the enhancement saved as a Photos edit so "Revert to Original" restores the untouched scan.
- In a folder: two files, the enhanced one and the untouched one with `_original` added to its name.

### Order of work

One pull request per step, each with its own beads issue under one parent issue:

1. Colour correction and the two photo scan profiles (including the settings-migration safeguard).
2. *The companion project, Appearance and file output, runs here.*
3. Photo cropping.
4. Face-based rotation.
5. Back captions, including detecting prints fed back-side-first.
6. Saving to Photos.
7. Auto-enhance.

### Test prints

The owner provides about ten real prints when each step reaches testing: blank backs, backs with only brand printing, backs with lab printing, handwritten backs, a very dark print and a wallet-size print.

## Left to the builder

- Names and shapes of new `ScanProfile` fields and settings text, within the wording rules above.
- Edge-detection method for photo cropping and the thresholds for faces, text, brand printing and lab printing, tuned on the test prints.
- How Yomi tells the picture side from the back.
- How face detection maps to a rotation (face roll angles, or comparing orientations).
- Image metadata fields used for the caption, as long as Photos and Finder search both see it.
- Where code lives between `YomiKit` and `YomiApp`, following existing patterns; PhotoKit code may live in the app.
- Unit tests built from synthetic images and macOS's own colour profiles.
