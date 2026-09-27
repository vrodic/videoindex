// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoIndex",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VideoIndex",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
