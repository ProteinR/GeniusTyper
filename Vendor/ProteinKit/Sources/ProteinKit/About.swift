import SwiftUI

/// The author's pages. A landing page will join (or replace) the GitHub profile later; change it
/// here and every app gets it with its next ProteinKit version.
public enum Links {
    public static let author = URL(string: "https://github.com/ProteinR")!
    /// The link's visible text.
    public static let authorTitle = "github.com/ProteinR"
}

/// The app's own version, as shown to the user.
public enum AppInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

/// The quiet line at the bottom of the settings list (MeetRec's): "<App> <version>", selectable,
/// and a link to the author. `.horizontal` for a full-width list, `.vertical` for a narrow sidebar.
/// No divider: the app puts one above it where its layout needs it.
public struct AboutFooter: View {
    private let appName: String
    private let version: String
    private let axis: Axis

    public init(appName: String, version: String = AppInfo.version, axis: Axis = .horizontal) {
        self.appName = appName
        self.version = version
        self.axis = axis
    }

    public var body: some View {
        Group {
            switch axis {
            case .horizontal:
                HStack(spacing: 10) {
                    versionText
                    Spacer(minLength: 4)
                    authorLink
                }
            case .vertical:
                VStack(alignment: .leading, spacing: 4) {
                    versionText
                    authorLink
                }
            }
        }
        .font(.caption)
    }

    private var versionText: some View {
        Text(verbatim: "\(appName) \(version)")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var authorLink: some View {
        Link(destination: Links.author) {
            Label(Links.authorTitle, systemImage: "arrow.up.right.square")
        }
        .help(Text("Автор \(appName) на GitHub", bundle: .module))
    }
}
