// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OsmoVault",
    // 15.0：网格"真正可见才加载"用 onScrollVisibilityChange（macOS 15 起提供）
    platforms: [.macOS("15.0")],
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

