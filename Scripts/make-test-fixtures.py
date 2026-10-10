#!/usr/bin/env python3
"""Generates the media fixtures used by MetadataWashTests.

Development-only: this uses ffmpeg, exiftool and sips from the developer's
machine to *create* deliberately metadata-laden files. The app itself never
depends on these tools being installed.

Run from the repository root:  python3 Scripts/make-test-fixtures.py
"""

from __future__ import annotations

import json
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Metadata WashTests" / "Fixtures"
DISPLAY_P3 = "/System/Library/ColorSync/Profiles/Display P3.icc"

A1111_PARAMETERS = (
    "a lighthouse on a cliff at dusk, volumetric light\n"
    "Negative prompt: blurry, lowres\n"
    "Steps: 30, Sampler: DPM++ 2M Karras, CFG scale: 7, Seed: 1234567890, "
    "Size: 128x96, Model hash: 31e35c80fc, Model: sd_xl_base_1.0, Version: v1.10.1"
)
COMFY_PROMPT = json.dumps(
    {"3": {"class_type": "KSampler", "inputs": {"seed": 42, "steps": 20, "cfg": 8}},
     "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "flux1-dev.safetensors"}}}
)
COMFY_WORKFLOW = json.dumps({"last_node_id": 9, "nodes": [{"id": 3, "type": "KSampler"}], "version": 0.4})
AI_XMP = """<?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
 <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
  <rdf:Description rdf:about=''
    xmlns:Iptc4xmpExt='http://iptc.org/std/Iptc4xmpExt/2008-02-29/'
    xmlns:xmp='http://ns.adobe.com/xap/1.0/'
    xmlns:dc='http://purl.org/dc/elements/1.1/'>
   <Iptc4xmpExt:DigitalSourceType>http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia</Iptc4xmpExt:DigitalSourceType>
   <xmp:CreatorTool>ComfyUI</xmp:CreatorTool>
   <dc:creator><rdf:Seq><rdf:li>Test Author</rdf:li></rdf:Seq></dc:creator>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>"""


def run(*args: str) -> None:
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def exiftool(path: Path, *tags: str) -> None:
    run("exiftool", "-q", "-overwrite_original", *tags, str(path))


def png_chunk(ctype: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(ctype + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + ctype + payload + struct.pack(">I", crc)


def insert_png_chunks(path: Path, chunks: list[bytes]) -> None:
    """Inserts chunks right after IHDR."""
    data = path.read_bytes()
    ihdr_len = struct.unpack(">I", data[8:12])[0]
    split = 8 + 12 + ihdr_len
    path.write_bytes(data[:split] + b"".join(chunks) + data[split:])


def make_png(tmp: Path, jumbf: bytes) -> None:
    dest = OUT / "ai-generated.png"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96",
        "-frames:v", "1", str(dest))
    icc = Path(DISPLAY_P3).read_bytes()
    chunks = [
        png_chunk(b"iCCP", b"Display P3\x00\x00" + zlib.compress(icc)),
        png_chunk(b"tEXt", b"parameters\x00" + A1111_PARAMETERS.encode("latin-1")),
        png_chunk(b"tEXt", b"prompt\x00" + COMFY_PROMPT.encode("latin-1")),
        png_chunk(b"tEXt", b"workflow\x00" + COMFY_WORKFLOW.encode("latin-1")),
        png_chunk(b"tEXt", b"Software\x00NovelAI"),
        png_chunk(b"zTXt", b"Comment\x00\x00" + zlib.compress(b'{"prompt": "a cat", "sampler": "k_euler"}')),
        png_chunk(b"iTXt", b"XML:com.adobe.xmp\x00\x00\x00\x00\x00" + AI_XMP.encode("utf-8")),
        png_chunk(b"tIME", struct.pack(">HBBBBB", 2026, 5, 4, 12, 30, 0)),
        png_chunk(b"caBX", jumbf),
    ]
    insert_png_chunks(dest, chunks)
    # eXIf with camera + GPS tags.
    exiftool(dest, "-EXIF:Make=FixtureCam", "-EXIF:Model=FC-1", "-EXIF:GPSLatitude=59.3293",
             "-EXIF:GPSLatitudeRef=N", "-EXIF:GPSLongitude=18.0686", "-EXIF:GPSLongitudeRef=E")


def make_jpeg(tmp: Path) -> None:
    dest = OUT / "camera-ai.jpg"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120",
        "-frames:v", "1", "-q:v", "3", str(dest))
    thumb = tmp / "thumb.jpg"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=40x30",
        "-frames:v", "1", str(thumb))
    exiftool(
        dest,
        f"-ICC_Profile<={DISPLAY_P3}",
        f"-ThumbnailImage<={thumb}",
        "-Make=FixtureCam", "-Model=FC-1", "-SerialNumber=SN-0042", "-LensModel=FC 24mm F1.8",
        "-DateTimeOriginal=2026:05:04 12:30:00", "-CreateDate=2026:05:04 12:30:00",
        "-Software=Midjourney v7", "-Artist=Test Author",
        "-Orientation#=6",
        "-GPSLatitude=59.3293", "-GPSLatitudeRef=N", "-GPSLongitude=18.0686", "-GPSLongitudeRef=E",
        "-GPSAltitude=12",
        f"-UserComment={A1111_PARAMETERS}",
        "-IPTC:Keywords=lighthouse", "-IPTC:By-line=Test Author",
        "-XMP-iptcExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
        "-XMP-xmp:CreatorTool=DALL-E 3",
        "-Comment=Generated by AI (DALL-E)",
    )


def make_webp(tmp: Path) -> None:
    dest = OUT / "ai-generated.webp"
    src = tmp / "webp-src.png"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96",
        "-frames:v", "1", str(src))
    run("cwebp", "-quiet", "-lossless", str(src), "-o", str(dest))
    exiftool(dest, f"-ICC_Profile<={DISPLAY_P3}", "-Make=FixtureCam", "-Software=Stable Diffusion",
             "-DateTimeOriginal=2026:05:04 12:30:00", "-GPSLatitude=59.3293", "-GPSLatitudeRef=N",
             "-XMP-iptcExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")


def make_sips_variant(tmp: Path, fmt: str, name: str) -> None:
    src = tmp / "src.png"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96",
        "-frames:v", "1", str(src))
    dest = OUT / name
    run("sips", "-s", "format", fmt, str(src), "--out", str(dest))
    exiftool(dest, "-Make=FixtureCam", "-Model=FC-1", "-Software=Adobe Firefly",
             "-DateTimeOriginal=2026:05:04 12:30:00",
             "-GPSLatitude=59.3293", "-GPSLatitudeRef=N", "-GPSLongitude=18.0686", "-GPSLongitudeRef=E",
             "-XMP-iptcExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")


def make_mp4(tmp: Path) -> None:
    dest = OUT / "tagged.mp4"
    run(
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=1",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-metadata", "title=Sora generation 42",
        "-metadata", "comment=prompt: a lighthouse at dusk",
        "-metadata", "artist=Test Author",
        "-metadata", "creation_time=2026-05-04T12:30:00Z",
        "-metadata", "location=+59.3293+018.0686/",
        "-metadata:s:v:0", "handler_name=Sora Video Handler",
        "-metadata:s:a:0", "handler_name=Sora Audio Handler",
        "-metadata:s:a:0", "language=eng",
        str(tmp / "base.mp4"),
    )
    # Rotation lives in the track matrix (display matrix side data), not in tags.
    run("ffmpeg", "-y", "-loglevel", "error", "-display_rotation:v:0", "90",
        "-i", str(tmp / "base.mp4"), "-c", "copy", "-map_metadata", "0", str(dest))
    exiftool(dest, "-Keys:Make=FixtureCam", "-Keys:Model=FC-1", "-Keys:Software=Runway Gen-4",
             "-XMP-dc:Creator=Test Author",
             "-XMP-iptcExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")


def make_hdr_mov(tmp: Path) -> None:
    dest = OUT / "hdr10.mov"
    run(
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=1",
        "-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le",
        "-x265-params",
        "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
        "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400",
        "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
        "-metadata", "creation_time=2026-05-04T12:30:00Z",
        "-metadata", "encoder=Veo 3 Renderer",
        str(dest),
    )
    exiftool(dest, "-Keys:Make=Apple", "-Keys:Model=iPhone 17 Pro",
             "-Keys:GPSCoordinates=59.3293 18.0686", "-Keys:Software=26.0")


def make_webm(tmp: Path) -> None:
    dest = OUT / "tagged.webm"
    run(
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=1",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:v", "libvpx-vp9", "-b:v", "200k", "-c:a", "libopus", "-shortest",
        "-metadata", "title=Kling generation",
        "-metadata", "comment=prompt: a lighthouse at dusk",
        "-metadata", "artist=Test Author",
        "-metadata:s:v:0", "title=AI video track",
        str(dest),
    )


def copy_c2pa_fixtures(c2pa_swift: Path) -> bytes:
    resources = c2pa_swift / "TestShared" / "Resources"
    shutil.copy(resources / "adobe-20220124-CI.jpg", OUT / "c2pa-signed.jpg")
    shutil.copy(resources / "video1.mp4", OUT / "c2pa-signed.mp4")
    shutil.copy(resources / "es256_certs.pem", OUT / "es256_certs.pem")
    shutil.copy(resources / "es256_private.key", OUT / "es256_private.key")
    jumbf = subprocess.run(["exiftool", "-b", "-JUMBF", str(OUT / "c2pa-signed.jpg")],
                           check=True, capture_output=True).stdout
    return jumbf


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make-test-fixtures.py <path to c2pa-swift checkout>", file=sys.stderr)
        return 2
    for tool in ("ffmpeg", "exiftool", "sips", "cwebp"):
        if shutil.which(tool) is None:
            print(f"missing development tool: {tool}", file=sys.stderr)
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        jumbf = copy_c2pa_fixtures(Path(sys.argv[1]))
        make_png(tmp, jumbf)
        make_jpeg(tmp)
        make_webp(tmp)
        make_sips_variant(tmp, "tiff", "photo.tiff")
        make_sips_variant(tmp, "heic", "photo.heic")
        make_sips_variant(tmp, "avif", "photo.avif")
        make_mp4(tmp)
        make_hdr_mov(tmp)
        make_webm(tmp)
    for f in sorted(OUT.iterdir()):
        print(f"{f.stat().st_size:>9}  {f.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
