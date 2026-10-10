// swift-tools-version: 6.0
// Hot reload for xtool apps on a real iPhone, driven from Linux by
// `ios-run --live` (see ~/.local/share/ios-run/docs/HOW-IT-WORKS.md).
// Debug builds only: in release builds everything here compiles to no-ops.
import PackageDescription

let package = Package(
    name: "HotReload",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HotReload", targets: ["HotReload"])],
    targets: [.target(name: "HotReload")]
)
