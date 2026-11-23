// swift-tools-version: 6.2
// CommsKit — Comms' shared Swift package (macOS now, iOS later). Talks only to the Prism server.
import PackageDescription

let prismKitPath = Context.environment["PRISMKIT_PATH"] ?? "../../prism/swift/PrismKit"

let package = Package(
    name: "CommsKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CommsCore", targets: ["CommsCore"]),
        .library(name: "CommsUI", targets: ["CommsUI"]),
        .library(name: "CommsTestSupport", targets: ["CommsTestSupport"]),
    ],
    dependencies: [
        // PrismKit lives in the Prism repository (swift/PrismKit), which is not a Swift package at
        // its root, so it is a local path dependency. Clone Prism next to this repository
        // (../prism) or point PRISMKIT_PATH at your checkout's swift/PrismKit. See README.md.
        .package(path: prismKitPath),
    ],
    targets: [
        .target(name: "CommsCore", dependencies: [
            .product(name: "PrismAuth", package: "PrismKit"),
            .product(name: "PrismTransport", package: "PrismKit"),
            .product(name: "PrismModels", package: "PrismKit"),
            .product(name: "CommsClient", package: "PrismKit"),
            .product(name: "OmniClient", package: "PrismKit"),
        ]),
        .target(name: "CommsUI", dependencies: [
            "CommsCore",
            .product(name: "PrismModels", package: "PrismKit"),
        ], exclude: ["List/NetworkMarks-LICENSE.md"], resources: [.copy("Resources/emoji.tsv")]),
        .target(name: "CommsTestSupport", dependencies: [
            "CommsCore",
            .product(name: "PrismModels", package: "PrismKit"),
            .product(name: "PrismTransport", package: "PrismKit"),
            .product(name: "OmniClient", package: "PrismKit"),
        ], resources: [.copy("Fixtures")]),
        .testTarget(name: "CommsCoreTests", dependencies: ["CommsCore", "CommsTestSupport"]),
        // Snapshot references live in __Snapshots__ and are read by path (#filePath) so
        // RECORD_SNAPSHOTS=1 can rewrite them in the source tree.
        .testTarget(name: "CommsUITests", dependencies: [
            "CommsUI", "CommsCore", "CommsTestSupport",
            .product(name: "PrismModels", package: "PrismKit"),
            .product(name: "PrismAuth", package: "PrismKit"),
            .product(name: "PrismTransport", package: "PrismKit"),
        ], exclude: ["__Snapshots__"]),
    ],
    swiftLanguageModes: [.v6]
)
