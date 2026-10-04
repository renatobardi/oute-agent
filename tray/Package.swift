// swift-tools-version:5.9
// Tray do oute-agent (#260, ADR-08 §10): TrayCore (sem tela, testável) + o app de barra de menu, só no macOS.
import PackageDescription

var products: [Product] = [.library(name: "TrayCore", targets: ["TrayCore"])]
var targets: [Target] = [
    .target(name: "TrayCore"),
    .testTarget(name: "TrayCoreTests", dependencies: ["TrayCore"]),
]
#if os(macOS)
products.append(.executable(name: "OuteTray", targets: ["OuteTray"]))
targets.append(.executableTarget(name: "OuteTray", dependencies: ["TrayCore"]))
#endif

let package = Package(
    name: "OuteTray",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
