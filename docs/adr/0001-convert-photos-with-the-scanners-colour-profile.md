# Convert photos with the scanner's colour profile instead of embedding it

Photo pages are converted from the S1300 colour profile into Display P3 when they are saved, rather than saved with the scanner's profile embedded. The profile would add 650 KB to every photo, a large share of a small HEIC file, and not every app honours unusual embedded scanner profiles. The conversion cannot be undone on photos already saved.

The colour profile is Fujitsu's file. It is never committed to this repository; Yomi finds it in the installed ScanSnap Manager at runtime, or the user chooses it in Settings, in the same way as the firmware.
