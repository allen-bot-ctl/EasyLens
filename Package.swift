// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyLens",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "EasyLens", targets: ["EasyLens"])],
    targets: [
        .executableTarget(
            name: "EasyLens",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ImageIO"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(name: "EasyLensTests", dependencies: ["EasyLens"]),
    ],
    swiftLanguageModes: [.v5]
)
