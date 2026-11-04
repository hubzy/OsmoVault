// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OsmoVault",
    // FrameCutKit 的本地化资源（String Catalog）需要声明默认语言
    defaultLocalization: "zh-Hans",
    // 15.0：网格"真正可见才加载"用 onScrollVisibilityChange（macOS 15 起提供）
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "OsmoVault", targets: ["OsmoVault"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0")
    ],
    targets: [
        // ===== 剪辑引擎（移植自开源项目 FrameCut，MIT，见 Vendor/FrameCutKit-LICENSE.txt）=====
        // FCCore：工程数据模型（Project/Clip/字幕/音频）+ 撤销栈 + 工程文件读写
        .target(
            name: "FCCore",
            path: "Vendor/FCCore",
            resources: [.process("Localizable.xcstrings")]
        ),
        // FCMedia：媒体探测、缩略图、波形
        .target(
            name: "FCMedia",
            dependencies: ["FCCore"],
            path: "Vendor/FCMedia",
            resources: [.process("Localizable.xcstrings")]
        ),
        // FCEngine：合成构建、调色 LUT、字幕/文字渲染、导出器
        // （原项目的 FCTranscribe/WhisperKit 模块未引入，字幕识别不随包）
        .target(
            name: "FCEngine",
            dependencies: ["FCCore"],
            path: "Vendor/FCEngine",
            resources: [.process("Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "OsmoVault",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "FCCore",
                "FCMedia",
                "FCEngine"
            ],
            path: "Sources/OsmoVault"
        ),
    ],
    // 语言模式保持 v5：主程序是既有代码，不做 Swift 6 严格并发改造
    swiftLanguageModes: [.v5]
)
