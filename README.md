# Handwriting Eraser

A macOS 15+ SwiftUI prototype that detects handwriting in PDFs on-device. It
uses a local handwriting segmentation model and repairs the detected pixels
with deterministic local background interpolation. It does not upload PDF
pages or use generative inpainting.

## Download and install

1. Download the universal DMG and its `.sha256` file from
   [the latest release](https://github.com/codingnooob/handwriting-eraser/releases/latest).
   It runs on Apple silicon and Intel Macs with macOS 15 or later.
2. Optionally verify the download in Terminal from the folder containing both files,
   using the downloaded version number, for example:
   `shasum -a 256 -c HandwritingEraser-1.0.0-macOS-universal.dmg.sha256`.
3. Open the DMG and drag **Handwriting Eraser.app** to **Applications**.
4. The initial release is ad-hoc signed, **not notarized by Apple**. If macOS
   blocks the app, use **System Settings → Privacy & Security → Open Anyway**
   after verifying that you trust the download. Later notarized releases will
   say so in their release notes.
5. Open the app and install the local handwriting detector when prompted.

## Build and run

```bash
swift build
swift run HandwritingEraser
```

Swift Package Manager downloads ONNX Runtime when building for the first time.
This package currently targets macOS, not iOS.

## Use

1. Choose **Import PDF** and select a PDF.
2. Choose **Download Local AI Model**. The pinned handwriting detector is about
   176 MB (168 MiB); the download needs an internet connection. Its size and
   SHA-256 hash are checked before it is installed in
   `~/Library/Application Support/HandwritingEraser/`.
3. Choose **Remove Handwriting**. The app processes pages locally, saves a new
   PDF in `~/Documents/`, and lets you switch between the original and cleaned
   previews. The original PDF is not modified.

**Review the result carefully.** Detection is imperfect: handwriting may remain,
while printed text, curves, diagrams, or overlapping print can be erased. Ink
that covers print cannot be reliably reconstructed. The model was trained
primarily on scanned worksheets, so performance varies with document type and
language. This is not a reliable redaction tool.

The exported PDF contains rasterized page images. It does not preserve selectable
text, links, form fields, bookmarks, or other original PDF structure. Password-
protected or damaged PDFs cannot currently be imported. Large PDFs can require
substantial memory and processing time.

Installation and processing errors are appended to
`~/Documents/handwriting-eraser-errors.log`. A previously installed LaMa model
may still be present in Application Support; this version does not use or delete
it.

## Tests

```bash
Scripts/test.sh
# Download and verify the real detector, load it through the app store, and
# verify cache restoration (requires internet; about 176 MB):
HANDWRITING_ERASER_INTEGRATION=1 Scripts/test.sh
# Run actual inference and a multipage export against the included synthetic
# worksheet using an already downloaded detector:
HANDWRITING_ERASER_DETECTOR_MODEL="$HOME/Library/Application Support/HandwritingEraser/HandwritingDetector-5b35de75b65da89fddc62e177b002f35b3b1f620.onnx" Scripts/test.sh
```

The test script explicitly loads the Swift Testing macro plugin when needed by
Command Line Tools. Some Command Line Tools versions emit missing framework
search-path linker warnings even when the build succeeds.

## Packaging and automatic releases

Build and inspect a universal DMG locally (Xcode 16.4 or newer, or a compatible
Swift 6 toolchain, is required):

```sh
Scripts/build-dmg.sh 1.2.0
Scripts/verify-dmg.sh dist/HandwritingEraser-1.2.0-macOS-universal.dmg 1.2.0
python3 -m unittest discover -s Tests/ReleaseAutomationTests -v
```

The workflow tests real model installation and inference on Apple silicon and
Intel. On pushes to `main`, after tests pass, it classifies **all commit messages
since the last published release**. Use Conventional Commit messages, including
the final squash-merge title when applicable:

- `feat:`, `fix:`, `perf:`, or `release:` makes a **minor** release (for example,
  `v1.2.0` → `v1.3.0`). Use `release:` for a packaging change that needs a DMG.
- A `!` after the type/scope (such as `feat!: ...`) or a `BREAKING CHANGE:`
  footer makes a **major** release (for example, `v1.2.0` → `v2.0.0`).
- Other commits, such as `docs:`, `ci:`, `chore:`, and `refactor:`, leave the
  version unchanged and do not publish a new package.

The first release is `v1.0.0`. If several changes are pending, the highest bump
wins; automated releases reset the patch component to zero. A failed run can be
retried with **Actions → Test and release → Run workflow** on `main`; a partial
draft is resumed only if its tag points to the same commit.

### Optional Developer ID signing and notarization

Without Apple credentials, the workflow ad-hoc signs the app and clearly labels
the DMG as unnotarized. To enable signing and notarization, add **all** of these
GitHub Actions repository secrets:

- `MACOS_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`
  certificate **with its private key**.
- `MACOS_CERTIFICATE_PASSWORD`: password used to export the `.p12`.
- `MACOS_SIGNING_IDENTITY`: full Developer ID Application identity name, as
  shown by `security find-identity -v -p codesigning`.
- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`: credentials
  and team ID accepted by Apple's `notarytool`.

The workflow fails rather than silently publishing an unsigned release if only
some credentials are configured. It signs the app and DMG, waits for Apple's
notarization, staples the ticket, verifies the DMG, and creates the checksum
*after* stapling. The signing/notarization path requires real credentials and
must be validated with your Apple Developer account.

## License

The app is [MIT licensed](LICENSE). Model and runtime dependencies have their
own licenses and notices.

## Model and runtime licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and license text.

- The [handwriting segmenter](https://huggingface.co/guoguo27/handwriting-segmenter)
  is Apache 2.0; see its [training repository and NOTICE](https://github.com/Illvuu/handwriting-segmenter)
  for attribution to DIS and Inoob/DIS-Handwriting-Remover.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) is MIT licensed.
- The legacy [LaMa Core ML package](https://huggingface.co/mlboydaisuke/LaMa-CoreML)
  is Apache 2.0 and is no longer required by the app.
