import Foundation

/// Opens the project chooser without restoring previously open project windows.
public enum WelcomeRoute {
    public static var url: URL { URL(string: "\(AppBuild.current.urlScheme)://welcome")! }
}
