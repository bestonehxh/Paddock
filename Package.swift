// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Paddock",
    platforms: [.macOS(.v26)],
    products: [
        // The macOS app (bundle it with Scripts/make-app.sh → build/Paddock.app).
        .executable(name: "PaddockApp", targets: ["PaddockApp"]),
    ],
    targets: [
        // vSphere SOAP (vim25) client: sessions, property collector, tasks, VM power and
        // snapshots, guest operations, keystrokes, console tickets. No dependencies.
        .target(name: "VimClient"),
        // WebMKS console: RFB over WebSocket, framebuffer decoding, input.
        .target(name: "MKSClient"),
        // Hosts, Keychain, the observable model shared by the app.
        .target(name: "PaddockCore", dependencies: ["VimClient", "MKSClient"]),
        .executableTarget(name: "PaddockApp", dependencies: ["PaddockCore", "VimClient", "MKSClient"],
                          path: "Sources/PaddockApp", exclude: ["Bundle"]),
        .testTarget(name: "VimClientTests", dependencies: ["VimClient"]),
        .testTarget(name: "MKSClientTests", dependencies: ["MKSClient"]),
        // Against the lab ESXi only (PADDOCK_HOST / PADDOCK_USER / PADDOCK_PASS); skipped otherwise.
        .testTarget(name: "LiveTests", dependencies: ["VimClient", "MKSClient", "PaddockCore"]),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore"]),
    ],
    swiftLanguageModes: [.v6]
)
