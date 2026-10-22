// swift-tools-version:5.7.1
import PackageDescription

let package = Package(
    name: "ios-tuvali-library",
    platforms: [
       .iOS(.v13)
    ],
    products: [
        .library(
            name: "ios-tuvali-library",
            targets: ["ios-tuvali-library"]),
    ],
    dependencies: [
        // Define our package's dependencies
        .package(url: "https://github.com/1024jp/GzipSwift", from: "5.2.0"),
        .package(url: "https://github.com/ivanesik/CrcSwift.git", from: "0.0.3"),
        // the same fork and requirement as pixelpass, so the wallet resolves one SwiftCBOR
        .package(url: "https://github.com/abhip2565/SwiftCBOR", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "ios-tuvali-library",
            dependencies: [
                // Include GzipSwift and CrcSwift as dependencies for this target
                .product(name: "Gzip", package: "GzipSwift"),
                .product(name: "CrcSwift", package: "CrcSwift"),
                .product(name: "SwiftCBOR", package: "SwiftCBOR")
            ]),
        .testTarget(
            name: "ios-tuvali-libraryTests",
            dependencies: ["ios-tuvali-library"]),
    ]
)
