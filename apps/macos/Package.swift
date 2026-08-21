// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrcaApp",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "COrca"),
        .executableTarget(
            name: "OrcaApp",
            dependencies: ["COrca"],
            linkerSettings: [
                .unsafeFlags(["-L../../zig-out/lib", "-lorca"]),
                .linkedFramework("AppKit"),
                .linkedFramework("MediaPlayer"),
            ]
        ),
    ]
)
