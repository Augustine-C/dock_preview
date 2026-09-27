// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DockPreview",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "DockPreview", targets: ["DockPreview"])],
    targets: [
        .target(name: "PreviewCore"),
        .executableTarget(name: "DockPreview", dependencies: ["PreviewCore"]),
        .testTarget(name: "PreviewCoreTests", dependencies: ["PreviewCore"])
    ],
    swiftLanguageModes: [.v5]
)
