// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WoWIDEFeasibility",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WoWIDEFeasibility", targets: ["WoWIDEFeasibility"])
    ],
    dependencies: [
        .package(path: "Vendor/CefSwift"),
        .package(path: "Vendor/Termini")
    ],
    targets: [
        .executableTarget(
            name: "WoWIDEFeasibility",
            dependencies: [
                .product(name: "CefKit", package: "CefSwift"),
                .product(name: "Termini", package: "Termini")
            ]
        )
    ]
)
