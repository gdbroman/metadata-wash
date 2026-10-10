**Metadata Wash** processes everything locally on your Mac. It never uploads files or contacts external services.

**ExifTool** by Phil Harvey — metadata inspection for all formats, and removal for TIFF, GIF, HEIC and AVIF. Free software under the same terms as Perl itself (Artistic License or GPL). https://exiftool.org

**FFmpeg** — container and stream metadata removal for videos by stream copy. This build is configured without GPL or non-free components and is licensed under the GNU Lesser General Public License v2.1 or later. Corresponding source: https://ffmpeg.org/releases/ (version and configure flags listed below). You may replace the bundled `ffmpeg`/`ffprobe` helpers in `Contents/Helpers` with your own build.

**C2PA Swift SDK** (Content Authenticity Initiative / Guardian Project) — reading and validating Content Credentials. MIT or Apache-2.0. Includes c2pa-rs (MIT/Apache-2.0), swift-crypto, swift-certificates and swift-asn1 (Apache-2.0). https://github.com/contentauth/c2pa-swift

**watermarks-remover** by Guillaume Meyer and contributors — C2PA/AI marker tables and the ISO BMFF C2PA box technique were adapted from this project. MIT License. https://github.com/guillaumemeyer/watermarks-remover

**remove-ai-watermarks** — AI metadata keys, generator tokens and vendor-specific provenance markers were adapted from this project. Apache License 2.0. https://github.com/wiltodelta/remove-ai-watermarks

Also consulted for coverage ideas (no code included): dropmarks (SwiftUI wrapper architecture), mat2, ExifCleaner and ImageMagick.
