// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LabDock",
    platforms: [.macOS(.v26)],
    products: [
        // The macOS app (bundle it with Scripts/make-app.sh → build/LabDock.app).
        .executable(name: "LabDockApp", targets: ["LabDockApp"]),
    ],
    targets: [
        // vSphere SOAP (vim25) client: sessions, property collector, tasks, VM power and
        // snapshots, guest operations, keystrokes, console tickets. No dependencies.
        .target(name: "VimClient"),
        // WebMKS console: RFB over WebSocket, framebuffer decoding, input.
        .target(name: "MKSClient"),
        // Hosts, Keychain, the observable model shared by the app.
        .target(name: "LabDockCore", dependencies: ["VimClient", "MKSClient"]),
        .executableTarget(name: "LabDockApp", dependencies: ["LabDockCore", "VimClient", "MKSClient"],
                          path: "Sources/LabDockApp", exclude: ["Bundle"]),
        .testTarget(name: "VimClientTests", dependencies: ["VimClient"]),
        .testTarget(name: "MKSClientTests", dependencies: ["MKSClient"]),
        // Against the lab ESXi only (LABDOCK_HOST / LABDOCK_USER / LABDOCK_PASS); skipped otherwise.
        .testTarget(name: "LiveTests", dependencies: ["VimClient", "MKSClient", "LabDockCore"]),
        .testTarget(name: "LabDockCoreTests", dependencies: ["LabDockCore"]),
        // The in-app updater (Sources/LabDockApp/Update): version/tag rules, signatures, the
        // install helper run for real in a scratch folder. No network.
        .testTarget(name: "LabDockAppTests", dependencies: ["LabDockApp"]),
    ],
    swiftLanguageModes: [.v6]
)
