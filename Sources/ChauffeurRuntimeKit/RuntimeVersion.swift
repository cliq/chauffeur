public enum RuntimeVersion {
    #if DEBUG
    public static let current = "0.1.0-dev"
    #else
    public static let current = "0.1.0"
    #endif
}
