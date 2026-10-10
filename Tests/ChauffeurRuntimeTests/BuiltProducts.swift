import Foundation

/// The package's executables, which SwiftPM builds next to the tests.
enum BuiltProducts {
    private final class Marker {}

    static func url(_ name: String) -> URL {
        let bundle = Bundle(for: Marker.self).bundleURL
        #if os(Linux)
        // Linux tests run from an executable whose bundle is the products directory itself.
        return bundle.appendingPathComponent(name)
        #else
        return bundle.deletingLastPathComponent().appendingPathComponent(name)
        #endif
    }
}
