# Text recognition and document understanding run in a helper after each batch

Yomi stays running in the menu bar so the user can scan at any time, but it scans rarely, so its idle memory matters more than the speed of any one batch. Searchable PDF text, sorting pages into documents, business cards, receipts and prints, reading their fields and naming files from their contents therefore run in a separate executable, `yomi-ocr`, which Yomi starts once a batch's pages are ready and which exits when it has saved them. Apple's text recognition keeps about 50 MB in the process that uses it until that process quits; Apple's on-device language model runs in a system service and adds almost nothing to the process that calls it. Only Apple's frameworks are used (Vision, DataDetection and FoundationModels), so there is nothing to download.

Turning pages upright and reading back captions stay inside Yomi, because they change the page before it is saved. After the first batch that uses them, Yomi keeps about 20 to 30 MB of Vision memory.

## Considered options

- **Everything inside Yomi.** Simplest, but the memory used by the first searchable PDF would stay for as long as Yomi runs.
- **An XPC service.** macOS starts it on demand but decides when to stop it. A child process that exits after each batch returns its memory at a known time, and works on files Yomi already has.
- **Open OCR models run with MLX**, such as GLM-OCR or PaddleOCR-VL. They read some pages Apple's recognizer gets wrong, such as white-on-black totals on receipts, but need 2 to 4 GB of memory while they run and a download of 1 GB or more. Worth reconsidering if Apple's recognizer is too weak on real scans, such as Japanese handwriting or faded receipts.

## Consequences

- If `yomi-ocr` is missing or fails, Yomi saves the batch as before, without a text layer or a name from its contents. Scanning never depends on it.
- The first text recognition after Yomi is updated can take about a minute while macOS prepares Vision's models for the new executable; later batches take well under a second a page.
- Sorting pages and reading fields need Apple Intelligence to be turned on. Without it, `yomi-ocr` still writes searchable PDFs and sorts by sheet size only.
