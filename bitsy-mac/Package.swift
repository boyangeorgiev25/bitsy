// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bitsy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BitsyKit", path: "Sources/BitsyKit"),
        .executableTarget(name: "Bitsy", dependencies: ["BitsyKit"], path: "Sources/Bitsy"),
        .executableTarget(name: "bitsy-mcp", dependencies: ["BitsyKit"], path: "Sources/bitsy-mcp"),
        .executableTarget(name: "bitsy-fand", dependencies: ["BitsyKit"], path: "Sources/bitsy-fand"),
        .executableTarget(name: "bitsy-statusline", path: "Sources/bitsy-statusline"),
    ]
)
