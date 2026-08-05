// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StockDeck",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "StockDeck",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "StockDeck",
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/AppLogo.png"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Fonts/InterVariable.ttf")
            ]
        ),
        .testTarget(
            name: "StockDeckTests",
            dependencies: ["StockDeck"],
            path: "Tests"
        ),
    ]
)

