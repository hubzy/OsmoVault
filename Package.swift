// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OsmoVault",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OsmoVault", targets: ["OsmoVault"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0")
    ],
    targets: [
        .executableTarget(
            name: "OsmoVault",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/OsmoVault"
        ),
    ]
)

