// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoordinatedCalendar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CoordinatedCalendar", targets: ["CoordinatedCalendar"]),
        .library(name: "CoordinatedCalendarCore", targets: ["CoordinatedCalendarCore"])
    ],
    targets: [
        .target(
            name: "CoordinatedCalendarCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "CoordinatedCalendar",
            dependencies: ["CoordinatedCalendarCore"],
            path: "Sources/CoordinatedCalendarApp",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "CoordinatedCalendarCoreTests",
            dependencies: ["CoordinatedCalendarCore"]
        )
    ]
)
