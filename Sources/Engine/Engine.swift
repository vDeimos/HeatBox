import Foundation

/// The product's identity. The name appears here and nowhere else in the
/// engine, so every message, folder and link scheme follows it (ADR-004).
public enum Engine {
    /// The name people see.
    public static let productName = "HeatBox"
    public static let bundleIdentifier = "local.studioxphobos.app"
    public static let version = "1.1.0"
    /// The folder under `~/Library/Application Support` that holds everything the app stores.
    public static let supportFolderName = "Studio x Phobos"
    /// The scheme of links that hand a page address to the app: `studioxphobos://open?url=…`.
    public static let urlScheme = "studioxphobos"
    /// The program inside the app bundle; the same name as the product in `Package.swift`.
    public static let executableName = "StudioXPhobos"
}
