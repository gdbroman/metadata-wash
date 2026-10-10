// swift-tools-version:5.9
// Development-only tool: signs test fixtures with C2PA Content Credentials using the
// public test certificate shipped with c2pa-swift. Not part of the app.
import PackageDescription

let package = Package(
    name: "C2PAFixtureSigner",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/contentauth/c2pa-swift", exact: "0.0.14")],
    targets: [.executableTarget(name: "C2PAFixtureSigner", dependencies: [.product(name: "C2PA", package: "c2pa-swift")])]
)
