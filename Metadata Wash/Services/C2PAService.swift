//
//  C2PAService.swift
//  Metadata Wash
//

import C2PA
import Foundation

/// Detects and summarizes C2PA Content Credentials with the native C2PA Swift SDK.
///
/// The SDK only *reads* manifests here; removal is done by the container-level
/// cleaners. Network access is refused through a custom HTTP resolver, so remote
/// manifests, OCSP checks and timestamp lookups never leave the Mac.
nonisolated enum C2PAService {
    private struct OfflineError: LocalizedError {
        var errorDescription: String? { "Metadata Wash works offline; remote C2PA resources are not fetched." }
    }

    static var supportedMimeTypes: Set<String> {
        Set(Reader.supportedMimeTypes)
    }

    static func inspect(_ url: URL, format: MediaFormat) -> C2PAStatus {
        let mime = format.mimeType
        guard supportedMimeTypes.contains(mime) else {
            return .notChecked(reason: "The C2PA SDK does not support \(format.displayName).")
        }
        do {
            let context = try C2PAContext(httpResolver: { _ in throw OfflineError() })
            let stream = try C2PAStream(readFrom: url)
            let reader = try Reader(context: context, format: mime, stream: stream)
            let json = try reader.json()
            var summary = summarize(json)
            summary.isEmbedded = reader.isEmbedded()
            summary.remoteManifestURL = reader.remote()?.absoluteString
            return .present(summary)
        } catch {
            let message = error.localizedDescription
            let lowered = message.lowercased()
            if lowered.contains("jumbfnotfound") || lowered.contains("no jumbf") || lowered.contains("manifestnotfound")
                || lowered.contains("not found") || lowered.contains("no manifest") {
                return .none
            }
            if lowered.contains("remote") || lowered.contains("offline") {
                return .unreadable(reason: "Refers to a remote manifest (not fetched).")
            }
            return .unreadable(reason: message)
        }
    }

    static func summarize(_ json: String) -> C2PASummary {
        var summary = C2PASummary(isEmbedded: true, remoteManifestURL: nil, manifestCount: 0, claimGenerators: [],
                                  title: nil, issuer: nil, signedAt: nil, actions: [], digitalSourceTypes: [],
                                  validationState: nil, validationIssues: [])
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return summary }
        let manifests = root["manifests"] as? [String: Any] ?? [:]
        summary.manifestCount = manifests.count
        summary.validationState = root["validation_state"] as? String
        summary.validationIssues = (root["validation_status"] as? [[String: Any]] ?? []).compactMap {
            ($0["explanation"] as? String) ?? ($0["code"] as? String)
        }
        let activeLabel = root["active_manifest"] as? String
        let ordered = manifests.sorted { lhs, _ in lhs.key == activeLabel }
        for (_, value) in ordered {
            guard let manifest = value as? [String: Any] else { continue }
            if let generator = manifest["claim_generator"] as? String { summary.claimGenerators.append(generator) }
            for info in manifest["claim_generator_info"] as? [[String: Any]] ?? [] {
                let name = [info["name"], info["version"]].compactMap { $0.map { "\($0)" } }.joined(separator: " ")
                if !name.isEmpty { summary.claimGenerators.append(name) }
            }
            if summary.title == nil { summary.title = manifest["title"] as? String }
            if let signature = manifest["signature_info"] as? [String: Any] {
                summary.issuer = summary.issuer ?? (signature["issuer"] as? String) ?? (signature["common_name"] as? String)
                summary.signedAt = summary.signedAt ?? (signature["time"] as? String)
            }
            for assertion in manifest["assertions"] as? [[String: Any]] ?? [] {
                guard let label = assertion["label"] as? String, label.hasPrefix("c2pa.actions"),
                      let data = assertion["data"] as? [String: Any] else { continue }
                for action in data["actions"] as? [[String: Any]] ?? [] {
                    if let name = action["action"] as? String { summary.actions.append(name) }
                    if let type = action["digitalSourceType"] as? String { summary.digitalSourceTypes.append(type) }
                }
            }
        }
        summary.claimGenerators = summary.claimGenerators.uniqued()
        summary.actions = summary.actions.uniqued()
        summary.digitalSourceTypes = summary.digitalSourceTypes.uniqued()
        return summary
    }
}

extension Array where Element: Hashable {
    nonisolated func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
