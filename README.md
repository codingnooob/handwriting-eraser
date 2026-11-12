# Handwriting Eraser

An iOS / macOS app that removes handwritten notes from a PDF using a **local,
on-device AI model**.

## What it does

1. **Import** a PDF (one or many pages) via the document picker.
2. **Render** each PDF page into an image so the local model can process it.
3. **Remove handwriting** with a local AI model (Core ML on Apple platforms).
   Handwriting ink is detected / inpainted away, producing a cleaned image per
   page.
4. **Export** the cleaned document as a new PDF.

All inference happens on the device; no image ever leaves the phone or Mac.

## Building

The project is a Swift package:

```bash
git clone <this repo>
cd anthias
swift build        # builds the HandwritingEraserKit library + HandwritingEraser app
swift run HandwritingEraser
```

The macOS app target (`HandwritingEraserApp`) is a SwiftUI app built with
`@main` / `App` / `WindowGroup`, and consumes the `HandwritingEraserKit` library.

To run on iOS, open the same sources inside an Xcode project with an iOS app
target that links `HandwritingEraserKit` (the library only uses
platform-agnostic CoreGraphics/AppKit types such as `NSImage`).

## Local AI model

The app runs a Core ML model locally:

- The cleaning logic lives in `CoreMLHandwritingRemovalModel`, which loads a
  local Core ML model file (`.mlmodel`) with `MLModel(contentsOf:)` and runs it
  with `MLModel.prediction(from:)` on device.
- The model is expected to accept a single RGB image input (batch of one:
  `[1, height, width, 3]`, float32) and produce an image (cleaned image or ink
  mask rendered as an RGBA image) as output; the result is converted into the
  cleaned page image.

### Adding a model

1. Convert an existing handwriting-removal / image-inpainting model (for example
   from ONNX/TensorFlow exports) to Core ML using
   [coremltools](https://coremltools.readme.io/):
   `python -m coremltools.convert ...`
2. Add the resulting `.mlmodel` to the app (e.g. as a bundle resource named
   `HandwritingRemover.mlmodel` so it is picked up by
   `Bundle.main.url(forResource: "HandwritingRemover", withExtension: "mlmodel")`).

## Architecture

```
Sources/
  HandwritingEraserKit/
    HandwritingRemovalModel.swift   // local AI protocol
    CoreMLHandwritingRemovalModel.swift // Core ML based local AI implementation
    PDFCleaningService.swift         // render -> clean -> write pipeline
    InkRemovalError.swift
  HandwritingEraserApp/
    HandwritingEraserApp.swift       // SwiftUI @main entry
    ContentView.swift                // SwiftUI UI (import, thumbnails, clean, export)
    EraserStore.swift                // Observable store: document state, cleaning
```

## License

MIT
