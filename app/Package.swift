// swift-tools-version:5.9
// DevStack menu-bar app. Built by bin/app (swift build -c release + a tiny bundling step); no Xcode project needed.
import PackageDescription

let package = Package(
	name: "DevStack",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "DevStack",
			path: "Sources/DevStack",
			linkerSettings: [.linkedFramework("ServiceManagement")]
		),
	]
)
