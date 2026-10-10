//
//  MetadataClassifier.swift
//  Metadata Wash
//

import Foundation

/// Maps raw ExifTool tags onto the app's normalized categories.
///
/// The key distinction is between *structural* values (describing how the file is
/// built: dimensions, codec configuration, sample tables), *rendering* values kept
/// on purpose (ICC profile, orientation, color/HDR signaling) and everything else,
/// which is removable metadata.
nonisolated enum MetadataClassifier {
    static func classify(_ tags: [ExifToolService.Tag], format: MediaFormat) -> [MetadataItem] {
        tags.compactMap { classify($0, format: format) }
    }

    static func classify(_ tag: ExifToolService.Tag, format: MediaFormat) -> MetadataItem? {
        let group = tag.family0 == tag.family1 ? tag.family0 : "\(tag.family0):\(tag.family1)"
        var item = MetadataItem(category: .other, group: group, name: tag.name, value: tag.value, source: .exifTool)

        if AISignatures.isC2PA(group: group, name: tag.name, value: tag.value) {
            item.category = .contentCredentials
            item.reason = "Content Credentials data"
            return item
        }
        let base = baseCategory(tag, format: format)
        item.category = base
        if base.isRemovable, let reason = AISignatures.aiReason(name: tag.name, value: tag.value) {
            item.category = .aiGeneration
            item.reason = reason
        }
        if base == .technical, (tag.name == "HandlerDescription" || tag.name == "CompressorName"),
           let reason = AISignatures.aiReason(name: tag.name, value: tag.value) {
            // Track handler names are structural, but AI video services put their name there.
            item.category = .aiGeneration
            item.reason = reason
        }
        if tag.family0 == "QuickTime", isZeroDate(tag.value), base == .timestamps {
            // Required header fields that have already been cleared.
            item.category = .technical
        }
        return item
    }

    // MARK: - Rules

    private static let renderingNames: Set<String> = [
        "Orientation", "ColorSpace", "Gamma", "InteropIndex", "SRGBRendering", "WhitePointX", "WhitePointY",
        "RedX", "RedY", "GreenX", "GreenY", "BlueX", "BlueY", "WhitePoint", "PrimaryChromaticities",
        "ColorPrimaries", "TransferCharacteristics", "MatrixCoefficients", "VideoFullRangeFlag", "ColorProfiles",
        "MaxContentLightLevel", "MaxPicAverageLightLevel", "MasteringDisplayPrimaries", "MasteringDisplayLuminance",
        "Rotation", "MatrixStructure", "ColorRepresentation", "ProfileName", "BackgroundColor", "SignificantBits",
        "TransparentColor", "ColorTransform", "DCTEncodeVersion", "APP14Flags0", "APP14Flags1", "Mirroring",
        "ImageRotation", "VideoRotation",
    ]

    private static let timestampWords = ["Date", "Time", "Timestamp", "TimeZone", "OffsetTime", "SubSec"]
    private static let structuralTimeNames: Set<String> = [
        "TimeScale", "MediaTimeScale", "PreviewTime", "PosterTime", "SelectionTime", "CurrentTime", "TimecodeScale",
        "Duration", "TrackDuration", "MediaDuration", "PreviewDuration", "SelectionDuration", "ExposureTime",
        "FrameDuration", "TimeToSampleTable", "CompositionTimeToSample", "SampleTime",
    ]

    private static let cameraNames: Set<String> = [
        "Make", "Model", "LensMake", "LensModel", "LensInfo", "LensSerialNumber", "SerialNumber", "BodySerialNumber",
        "CameraSerialNumber", "InternalSerialNumber", "OwnerName", "CameraOwnerName", "UniqueCameraModel",
        "LocalizedCameraModel", "ImageUniqueID", "DeviceSettingDescription", "AndroidModel", "AndroidMake",
        "AndroidManufacturer", "ContentIdentifier", "LivePhotoAuto", "CameraID",
    ]

    private static let softwareNames: Set<String> = [
        "Software", "ProcessingSoftware", "HostComputer", "CreatorTool", "Encoder", "EncodedBy", "EncodingTool",
        "MuxingApp", "WritingApp", "SoftwareVersion", "HistorySoftwareAgent", "HandlerVendorID", "VendorID",
        "OriginatingProgram", "ProgramVersion", "ApplicationRecordVersion", "ClaimGenerator", "Producer",
    ]

    private static let peopleNames: Set<String> = [
        "Artist", "Author", "Creator", "Copyright", "CopyrightNotice", "Rights", "By-line", "By-lineTitle", "Credit",
        "Source", "Contact", "CreatorContactInfo", "OwnerID", "XPAuthor", "Owner", "UsageTerms", "WebStatement",
        "Marked", "CaptionWriter", "Writer-Editor", "PersonInImage", "RegionPersonDisplayName", "Publisher",
        "AlbumArtist", "Composer", "Director", "Performer", "Contributor",
    ]

    private static let commentNames: Set<String> = [
        "Comment", "UserComment", "XPComment", "ImageDescription", "Description", "Caption-Abstract", "Title",
        "ObjectName", "Headline", "Instructions", "SpecialInstructions", "Disclaimer", "Warning", "Notes",
        "XPTitle", "XPSubject", "Subject", "Information", "Synopsis", "Album", "Lyrics", "Keywords", "XPKeywords",
    ]

    private static func baseCategory(_ tag: ExifToolService.Tag, format: MediaFormat) -> MetadataCategory {
        let name = tag.name
        let g0 = tag.family0
        let g1 = tag.family1

        // Rendering information we keep on purpose.
        if g0 == "ICC_Profile" { return .rendering }
        if renderingNames.contains(name), !(g0 == "XMP") { return .rendering }
        if g0 == "Adobe" || g0 == "JFIF" { return g0 == "Adobe" ? .rendering : .technical }

        if g0 == "MakerNotes" || name.hasPrefix("MakerNote") { return .makerNotes }
        if g1 == "GPS" || g0 == "GPS" || name.hasPrefix("GPS") || name.contains("Location") && !name.contains("Offset")
            || name == "LocationInformation" || name == "ISO6709" {
            return .location
        }
        if g1 == "IFD1" || name.contains("Thumbnail") || name.contains("PreviewImage") || g0 == "MPF"
            || name == "PreviewTIFF" || name == "JpgFromRaw" || name == "OtherImage" || name == "CoverArt" {
            return .thumbnails
        }
        if g0 == "Photoshop" || g0 == "IPTC" || g0 == "XMP" || g0 == "FlashPix" {
            return xmpLikeCategory(name)
        }

        switch g0 {
        case "PNG": return pngCategory(name)
        case "RIFF": return riffCategory(name)
        case "QuickTime": return quickTimeCategory(tag, format: format)
        case "Matroska": return matroskaCategory(tag)
        case "GIF": return ["Comment", "XMPToolkit"].contains(name) ? .comments : .technical
        case "EXIF": return exifCategory(tag, format: format)
        case "JUMBF", "CBOR", "C2PA": return .contentCredentials
        case "Trailer": return .other
        default: break
        }
        if softwareNames.contains(name) { return .software }
        if cameraNames.contains(name) { return .camera }
        if isTimestamp(name) { return .timestamps }
        return .other
    }

    private static func xmpLikeCategory(_ name: String) -> MetadataCategory {
        if softwareNames.contains(name) { return .software }
        if cameraNames.contains(name) { return .camera }
        if peopleNames.contains(name) { return .people }
        if commentNames.contains(name) { return .comments }
        if isTimestamp(name) { return .timestamps }
        if name.hasPrefix("History") { return .software }
        return .descriptive
    }

    private static func exifCategory(_ tag: ExifToolService.Tag, format: MediaFormat) -> MetadataCategory {
        let name = tag.name
        // Image structure fields that live in TIFF IFDs.
        let structural: Set<String> = [
            "ImageWidth", "ImageHeight", "BitsPerSample", "Compression", "PhotometricInterpretation", "FillOrder",
            "StripOffsets", "SamplesPerPixel", "RowsPerStrip", "StripByteCounts", "PlanarConfiguration",
            "SampleFormat", "TileWidth", "TileLength", "TileOffsets", "TileByteCounts", "ExtraSamples",
            "Predictor", "SubfileType", "OldSubfileType", "YCbCrSubSampling", "YCbCrPositioning",
            "YCbCrCoefficients", "ReferenceBlackWhite", "XResolution", "YResolution", "ResolutionUnit",
            "ExifImageWidth", "ExifImageHeight", "ColorMap", "JPEGTables", "HalftoneHints", "InkSet",
            "ExifVersion", "FlashpixVersion", "ComponentsConfiguration", "InteropVersion", "SubIFD", "ExifOffset",
        ]
        if structural.contains(name) { return .technical }
        if softwareNames.contains(name) { return .software }
        if cameraNames.contains(name) { return .camera }
        if peopleNames.contains(name) { return .people }
        if commentNames.contains(name) { return .comments }
        if isTimestamp(name) { return .timestamps }
        return .camera   // exposure, lens, flash and other capture settings
    }

    private static func pngCategory(_ name: String) -> MetadataCategory {
        let structural: Set<String> = [
            "ImageWidth", "ImageHeight", "BitDepth", "ColorType", "Compression", "Filter", "Interlace",
            "PixelsPerUnitX", "PixelsPerUnitY", "PixelUnits", "Palette", "AnimationFrames", "AnimationPlays",
        ]
        if structural.contains(name) { return .technical }
        if softwareNames.contains(name) { return .software }
        if peopleNames.contains(name) { return .people }
        if isTimestamp(name) { return .timestamps }
        return .comments
    }

    private static func riffCategory(_ name: String) -> MetadataCategory {
        let structural: Set<String> = [
            "ImageWidth", "ImageHeight", "AlphaIsUsed", "VP8Version", "HorizontalScale", "VerticalScale",
            "AnimationLoopCount", "BackgroundColor", "AlphaPreprocessing", "AlphaFiltering", "AlphaCompression",
            "WebP_Flags", "FrameCount", "Duration",
        ]
        if structural.contains(name) { return .technical }
        if softwareNames.contains(name) { return .software }
        if isTimestamp(name) { return .timestamps }
        return .comments
    }

    private static func quickTimeCategory(_ tag: ExifToolService.Tag, format: MediaFormat) -> MetadataCategory {
        let name = tag.name
        let g1 = tag.family1
        // User-level metadata containers: everything inside is removable.
        let metadataGroups = ["Keys", "ItemList", "UserData", "Microsoft", "Meta", "AudioKeys", "VideoKeys",
                              "AudioUserData", "VideoUserData", "AudioItemList", "VideoItemList", "Track1Keys"]
        if metadataGroups.contains(where: { g1 == $0 }) || g1.hasSuffix("Keys") || g1.hasSuffix("UserData") || g1.hasSuffix("ItemList") {
            if name == "PrimaryItemReference" || name == "MetaVersion" || name == "MetaImageSize" { return .technical }
            if softwareNames.contains(name) || name == "Encoder" || name == "SoftwareVersion" { return .software }
            if cameraNames.contains(name) { return .camera }
            if peopleNames.contains(name) { return .people }
            if commentNames.contains(name) { return .comments }
            if isTimestamp(name) { return .timestamps }
            return .containerTags
        }
        // Movie, track and media headers: required structure, but they carry dates.
        let headerDates: Set<String> = ["CreateDate", "ModifyDate", "TrackCreateDate", "TrackModifyDate",
                                        "MediaCreateDate", "MediaModifyDate"]
        if headerDates.contains(name) { return .timestamps }
        if name == "HandlerVendorID" || name == "VendorID" {
            // FFmpeg writes its own vendor ID; Apple's 'appl' handler is required for iTunes-style metadata.
            return ["FFmpeg", "Apple"].contains(tag.value) || tag.value.isEmpty ? .technical : .software
        }
        if name == "Encoder" || name == "CompressorName", !tag.value.isEmpty {
            let generic = ["avc1", "hvc1", "hev1", "av01", "vp09", "HEVC", "H.264", "AVC Coding", "HEVC Coding", "ap4h", "apcn"]
            return generic.contains(tag.value) ? .technical : .software
        }
        if name == "HandlerDescription" { return .technical }
        // Movie/track headers, sample tables, codec configuration (Unknown_hvcC, Unknown_esds…)
        // and padding are structure. Vendor boxes outside these are caught by the BMFF scan.
        return .technical
    }

    private static func matroskaCategory(_ tag: ExifToolService.Tag) -> MetadataCategory {
        let name = tag.name
        if name == "MuxingApp" || name == "WritingApp" {
            // Required elements; FFmpeg's bit-exact mode writes the neutral value "Lavf".
            return tag.value == "Lavf" ? .technical : .software
        }
        if tag.family1.hasPrefix("Tags") || name.hasPrefix("Tag") && name != "TagTrackUID" {
            if commentNames.contains(name) || name == "Comment" { return .comments }
            if isTimestamp(name) { return .timestamps }
            return .containerTags
        }
        if name == "DateTimeOriginal" || name == "DateUTC" { return .timestamps }
        if name == "Title" { return .comments }
        if ["AttachedFileName", "AttachedFileData", "AttachedFileMIMEType", "AttachedFileDescription"].contains(name) {
            return .thumbnails
        }
        if ["ChapterDisplayString", "ChapterTitle", "ChapterString"].contains(name) { return .comments }
        if name == "TrackName" { return .containerTags }
        return .technical
    }

    static func isTimestamp(_ name: String) -> Bool {
        if structuralTimeNames.contains(name) { return false }
        return timestampWords.contains { name.contains($0) }
    }

    static func isZeroDate(_ value: String) -> Bool {
        value.hasPrefix("0000:00:00") || value.hasPrefix("1904:01:01 00:00:00") || value.hasPrefix("1970:01:01 00:00:00")
    }
}
