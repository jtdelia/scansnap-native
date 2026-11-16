# Yomi

Yomi drives ScanSnap S1300 and S1300i scanners from macOS and turns what goes through the feeder into saved documents and photos.

## Scanning

**Sheet**:
One physical item that passes through the feeder, scanned on both sides at once.
_Avoid_: Document (for a single item), paper

**Batch**:
All the sheets scanned in one go, from pressing Scan until the feeder is empty or the scan is stopped.
_Avoid_: Job, session, run

**Side**:
The front or the back of a sheet, as captured by the scanner.
_Avoid_: Face, surface

**Page**:
The finished image of one side, after processing, as it is saved.
_Avoid_: Image, scan

**Blank side**:
A side with too little ink to keep; it is dropped instead of becoming a page.
_Avoid_: Empty page

**Show-through**:
Ink from one side of a sheet that is faintly visible on the other side.
_Avoid_: Bleed-through (used only in settings text, to match ScanSnap Manager)

## Settings

**Scan profile**:
A named set of scan settings the user picks before scanning, such as quality, sides and where to save.
_Avoid_: Profile (on its own), preset, mode

**Name pattern**:
The pieces and typed text a scan profile uses to name its files, and optionally its subfolders.
_Avoid_: Template, naming scheme, format

**Colour profile**:
The scanner maker's description of how the scanner records colour, used to make saved colours match the original.
_Avoid_: Profile (on its own), ICC, ICM

## Photos

**Print**:
A paper photograph fed through the scanner.
_Avoid_: Photo (for the paper), picture

**Picture side**:
The side of a print that carries the photograph; the other side is its back.
_Avoid_: Front (when the print went in back-side-first)

**Photo**:
The saved picture made from a print, in a folder or in Apple Photos.
_Avoid_: Image, scan

**Back caption**:
Writing read from the back of a print and stored as the photo's caption; the back itself is not saved.
_Avoid_: Back note, annotation
