// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "云写君",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "云写君", targets: ["Typeless01App"])
    ],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(
            name: "Typeless01App",
            dependencies: ["CSQLite"],
            path: "Sources/TypelessApp"
        ),
        .testTarget(
            name: "Typeless01AppTests",
            dependencies: ["Typeless01App", "CSQLite"]
        )
    ]
)
