// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuickAsk",
    platforms: [
        // 代码依赖 macOS 26 API（NSGlassEffectView、.buttonStyle(.glass)、onScrollGeometryChange），
        // 如实声明；若需支持旧系统，需对上述 API 做 #available 分支降级。
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "AIQuickAsk",
            path: "Sources/AIQuickAsk"
        )
    ]
)
