# Metadata Wash

A local-first macOS app that finds and removes metadata from images and videos — camera and location data, AI-generation prompts and workflows, and C2PA Content Credentials — and creates clean copies without re-encoding. Nothing is uploaded; originals are never modified.

## How it works

1. **Add** files by dropping them on the window or Dock icon, with **Choose Files…**, or via *Open With*. Folders are expanded.
2. Each file is **cloned into a private workspace** in the app container (an instant copy-on-write clone on APFS). All engines work only on that copy.
3. **Inspection** runs every engine independently and merges the results into one normalized report (`MetadataReport`):
   - **ExifTool**: every tag, in every group.
   - **Native structure scanners** (`Services/Formats`): raw PNG chunks, JPEG segments, WebP chunks and ISO BMFF boxes. They catch C2PA containers, AI text chunks, trailers and vendor boxes even where tag parsers disagree.
   - **FFprobe**: stream-level tags, data tracks, chapters and attachments.
   - **C2PA Swift SDK**: reads and validates Content Credentials. Networking is refused through a custom HTTP resolver, so remote manifests, OCSP and timestamp lookups never leave the Mac.
   - **Extended attributes**: download source URLs (`kMDItemWhereFroms`), quarantine info and Finder tags.
4. **Cleaning** (`MetadataCleaner`) writes a new file using the engine that fits the format (see the table below).
5. **Verification** re-inspects the output with all engines. If ExifTool still finds a deletable tag, a targeted second pass removes it, and the output is inspected again. The status comes from that final inspection:
   - **Supported metadata removed**: no recognized removable metadata remains.
   - **Partially cleaned**: recognized metadata remains, and it is listed.
   - **Cleaned, verification limited**: an engine could not run.
   - **Failed**, **Unsupported** or **Cancelled**.
6. The verified copy is saved as `<name>-clean.<ext>` in the output folder (default `~/Downloads/Metadata Wash`). From there you can reveal, open or drag out each cleaned file.

### Engines per format

| Format | Removal | Pixels/samples |
|---|---|---|
| JPEG | Native segment filter. Keeps JFIF, the ICC profile and Adobe APP14. Re-adds a non-default orientation as a minimal EXIF block. Drops EXIF, XMP, IPTC, MPF, JUMBF/C2PA (APP11), comments and data after the end-of-image marker. Falls back to ExifTool if the file can't be parsed. | Scan bytes copied verbatim |
| PNG | Native chunk allow-list. Keeps IHDR, PLTE, IDAT, tRNS, gAMA, cHRM, sRGB, iCCP, sBIT, cICP, mDCV, cLLI, bKGD, pHYs and the APNG chunks. Drops tEXt/zTXt/iTXt (prompts, ComfyUI workflows), eXIf, tIME, caBX (C2PA) and everything else. | IDAT copied verbatim |
| WebP | Native RIFF filter. Keeps VP8/VP8L/VP8X/ALPH/ANIM/ANMF/ICCP and fixes the VP8X flags. | Bitstream copied verbatim |
| TIFF, GIF | ExifTool `-all=` with the ICC profile restored. A targeted pass removes IFD0 tags that `-all=` cannot. | Unchanged |
| HEIC, AVIF | ExifTool `-all=`, then native removal of C2PA/XMP `uuid` boxes. | Unchanged |
| MP4, MOV, M4V | FFmpeg remux: stream copy, `-map_metadata -1`, bit-exact mode. Data tracks, chapters and cover art are dropped; track languages are kept. If FFmpeg is missing or fails, a native in-place box neutralizer runs, followed by ExifTool. | Stream copy, no re-encoding |
| WebM, MKV | FFmpeg remux (as above). | Stream copy, no re-encoding |

The following are kept on purpose because removing them would change how the file looks or plays: the ICC profile, EXIF orientation, HEIF `irot`/`imir`, the video display matrix (rotation), HDR signaling (VUI/SEI and `colr`, `mdcv`, `clli`), timing and track languages.

C2PA in ISO BMFF files is removed **in place**: the box is relabelled `free` and its payload zeroed. No byte moves, so the `stco`/`co64`/`iloc` offsets stay valid. This technique comes from watermarks-remover.

### AI provenance coverage

`Services/AISignatures.swift` recognizes:

- **Generation data**: Stable Diffusion/A1111 `parameters`, ComfyUI `prompt`/`workflow`, InvokeAI, Fooocus and NovelAI chunks.
- **IPTC labels**: `DigitalSourceType` values `trainedAlgorithmicMedia` and `compositeWithTrainedAlgorithmicMedia`, plus the IPTC 2025.1 AI fields.
- **China TC260 `AIGC` labels.**
- **Generator names**, only in fields that name software (Midjourney, DALL·E, Firefly, Sora, Veo, Kling, Runway…).
- **Other vendor markers**: Samsung Galaxy AI trailers and the C2PA cloud-manifest repositories.

Content Credentials are detected three independent ways:

- by the C2PA SDK;
- by ExifTool's JUMBF/CBOR groups;
- by the structure scanners (APP11, `caBX`, the WebP `C2PA` chunk, the BMFF ContentProvenance UUID).

### What metadata cleaning cannot do

These limits are reported in the app rather than hidden:

- **Pixel watermarks.** Invisible watermarks embedded in pixels or frames, such as SynthID, are content, not metadata. The app never alters pixels or frames. `PixelAnalysisStage` is the extension point for future detectors. No ML runtime or model ships with the app.
- **Durable Content Credentials.** These can still be looked up from a soft-binding watermark or fingerprint after the embedded manifest is removed.
- **Bitstream encoder strings.** Encoder settings inside the compressed video bitstream, such as x264/x265 SEI, can only be removed by re-encoding. They are listed as "Not removable without re-encoding".
- **MPF secondary images.** JPEG secondary images such as HDR gain maps and depth maps are removed along with the rest of the trailer. The app warns when this happens.

## Building

Requirements: Xcode 27 or later and macOS 26.6 or later (the deployment target).

```bash
Scripts/fetch-exiftool.sh
```

```bash
Scripts/build-ffmpeg.sh
```

Then open `Metadata Wash.xcodeproj` and run. Both scripts are pinned and checksum-verified. Their output goes to `Vendor/`, which is not committed. The **Embed Metadata Engines** build phase (`Scripts/embed-engines.sh`) does three things:

- copies ExifTool to `Contents/Resources/exiftool`;
- copies `ffmpeg`/`ffprobe` to `Contents/Helpers` and signs them with the hardened runtime and the sandbox `inherit` entitlement (`Config/Helper.entitlements`);
- copies the license texts to `Contents/Resources/Licenses`.

### Tests

```bash
xcodebuild -project "Metadata Wash.xcodeproj" -scheme "Metadata Wash" -destination 'platform=macOS' test
```

The tests run inside the sandboxed app host, so they exercise the real bundled engines. Fixtures live in `Metadata WashTests/Fixtures`:

- `Scripts/make-test-fixtures.py` generates them with development tools. These tools are never used by the app.
- `Scripts/C2PAFixtureSigner` signs some of them with the public c2pa-swift test certificate.

To also run the pipeline against a real file of your own:

```bash
TEST_RUNNER_METADATA_WASH_SAMPLE=/path/to/file.mp4 xcodebuild -project "Metadata Wash.xcodeproj" -scheme "Metadata Wash" -destination 'platform=macOS' test
```

## Dependencies

| Component | Version | Integration | License |
|---|---|---|---|
| [c2pa-swift](https://github.com/contentauth/c2pa-swift) | 0.0.14 (exact) | Swift Package Manager | MIT / Apache-2.0 |
| [ExifTool](https://github.com/exiftool/exiftool) | 13.59 | Bundled Perl script, run by `/usr/bin/perl` | Perl (Artistic / GPL) |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | 9.0.2 | Bundled universal static helpers | LGPL-2.1+ (no GPL/non-free components) |
| [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover) | — | Ported marker tables and BMFF technique | MIT |
| [remove-ai-watermarks](https://github.com/wiltodelta/remove-ai-watermarks) | — | Ported AI key/token lists | Apache-2.0 |

[dropmarks](https://github.com/Nicktili72/dropmarks), [mat2](https://github.com/jvoisin/mat2), [ExifCleaner](https://github.com/szTheory/exifcleaner) and [ImageMagick](https://github.com/ImageMagick/ImageMagick) were consulted for architecture and coverage only. No code from them is included. ImageMagick was not used because it decodes and re-encodes pixels.

The FFmpeg build has no encoders, decoders or external libraries. It contains only the MOV/Matroska demuxers and muxers, parsers and bitstream filters, and links only against system libraries. Each binary is about 8 MB, universal (arm64 + x86_64), with a minimum of macOS 14. Help › Third-Party Notices lists every license, the FFmpeg source URL and the configure flags. The helpers can be replaced with a user-supplied build, as the LGPL requires.

## Distribution notes

- **Developer ID and notarization.** The helpers are signed during the build. Release builds with a real identity get a secure timestamp. Archive and export re-sign nested code with your Developer ID. Notarization accepts the `.pm`/script resources, which are not Mach-O files.
- **Sandbox.** The app uses three entitlements: user-selected files (read/write), the Downloads folder (read/write) for the default output location, and app-scoped bookmarks to remember a custom output folder. Child processes inherit the sandbox, and they only touch files inside the container workspace.
- **Mac App Store risks.** These need separate review:
  - Running `/usr/bin/perl` from a sandboxed app is allowed today, but Apple has signalled that scripting runtimes may be removed from macOS. If that happens, ExifTool needs a bundled relocatable Perl. Until then the native JPEG/PNG/WebP and FFmpeg paths keep working.
  - Reviewers may ask about the bundled interpreter-run code.
  - LGPL helpers are generally accepted on the App Store if relinking or replacement is possible. Get legal advice for your situation.
