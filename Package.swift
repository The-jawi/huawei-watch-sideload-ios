// swift-tools-version:5.9
// Unit tests for parsing code that needs no watch: run "swift test". The iOS app itself is built with XcodeGen
// (generate.sh); this package only compiles the files listed in "sources".
import PackageDescription

let package = Package(
    name: "HuaSideloadParsing",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(
            name: "HuaSideloadParsing",
            path: "HuaSideload",
            exclude: ["Assets.xcassets"],
            sources: ["HiChainJSON.swift", "HuaweiProtocol.swift", "Localization.swift", "PairingSetup.swift",
                      "WatchFaceSupport.swift", "WatchFacePackage.swift", "CredentialStore.swift"]
        ),
        .testTarget(
            name: "HuaSideloadParsingTests",
            dependencies: ["HuaSideloadParsing"],
            path: "Tests/HuaSideloadParsingTests"
        ),
    ]
)
