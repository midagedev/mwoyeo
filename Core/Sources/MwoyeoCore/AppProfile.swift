import Foundation

/// Languages (and the added engine) remembered for one app. While that app is in front they replace the base choice.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var bundleID: String
    public var appName: String
    public var source: String
    public var target: String
    /// The added engine to use; nil keeps the base choice.
    public var customEngineID: UUID?

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, source: String, target: String, customEngineID: UUID? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
    }

    // Decode leniently so a profile saved by another version never takes the others with it.
    enum CodingKeys: String, CodingKey { case bundleID, appName, source, target, customEngineID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "auto"
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? "en"
        customEngineID = try? c.decodeIfPresent(UUID.self, forKey: .customEngineID)
    }
}

/// The part of the settings an app profile can override.
public struct LanguageChoice: Equatable, Sendable {
    public var source: String
    public var target: String
    public var customEngineID: UUID?

    public init(source: String, target: String, customEngineID: UUID?) {
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
    }
}

public enum AppProfiles {
    public static func profile(for bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.bundleID == bundleID }
    }

    /// What translates while `frontmost` is in front: the app's profile laid over `base`, or `base` itself when the app has
    /// none. A profile engine that is no longer among `engines` keeps the base choice.
    public static func effective(base: LanguageChoice, profiles: [AppProfile], frontmost: String?, engines: Set<UUID>) -> LanguageChoice {
        guard let p = profile(for: frontmost, in: profiles) else { return base }
        var out = LanguageChoice(source: p.source, target: p.target, customEngineID: base.customEngineID)
        if let id = p.customEngineID, engines.contains(id) { out.customEngineID = id }
        return out
    }

    /// `profiles` with `profile` added, or replacing the one for the same app.
    public static func remembering(_ profile: AppProfile, in profiles: [AppProfile]) -> [AppProfile] {
        var out = profiles
        if let i = out.firstIndex(where: { $0.bundleID == profile.bundleID }) { out[i] = profile } else { out.append(profile) }
        return out
    }
}
