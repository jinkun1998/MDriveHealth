/*
 * UpdateChecker.swift — lightweight update check against GitHub Releases.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

enum UpdateChecker {
    /// GitHub repository that hosts releases (owner/name).
    static let repository = "maclife-cloud/MDriveHealth"

    struct Release: Sendable {
        let version: String
        let url: URL
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the latest release when it is newer than the running build.
    static func checkForUpdate() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let tag = dict["tag_name"] as? String,
              let htmlURL = (dict["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(latest, than: currentVersion)
            ? Release(version: latest, url: htmlURL) : nil
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").compactMap { Int($0) }
        let rhs = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
