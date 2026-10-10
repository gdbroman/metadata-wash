// Usage: swift run C2PAFixtureSigner <fixtures dir>
// Signs a copy of each base fixture as "<name>-c2pa.<ext>" with an AI "created" action.
import C2PA
import Foundation

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let certificate = try String(contentsOf: fixtures.appending(path: "es256_certs.pem"), encoding: .utf8)
let key = try String(contentsOf: fixtures.appending(path: "es256_private.key"), encoding: .utf8)
let signer = SignerInfo(algorithm: .es256, certificatePEM: certificate, privateKeyPEM: key, tsa: nil)

let manifest = """
{
  "claim_generator_info": [{"name": "Fixture AI Studio", "version": "1.0"}],
  "title": "AI fixture",
  "assertions": [
    {"label": "c2pa.actions", "data": {"actions": [
      {"action": "c2pa.created",
       "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
       "softwareAgent": {"name": "Fixture Diffusion XL"}}
    ]}}
  ]
}
"""

let sources = ["ai-generated.png": "png", "ai-generated.webp": "webp", "photo.heic": "heic",
               "photo.avif": "avif", "photo.tiff": "tiff", "hdr10.mov": "mov"]
for (name, ext) in sources.sorted(by: { $0.key < $1.key }) {
    let source = fixtures.appending(path: name)
    let destination = fixtures.appending(path: "\((name as NSString).deletingPathExtension)-c2pa.\(ext)")
    try? FileManager.default.removeItem(at: destination)
    do {
        try C2PA.signFile(source: source, destination: destination, manifestJSON: manifest, signerInfo: signer)
        print("signed  \(destination.lastPathComponent)")
    } catch {
        print("skipped \(name): \(error)")
    }
}
