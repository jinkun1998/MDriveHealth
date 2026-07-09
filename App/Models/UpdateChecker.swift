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
        let downloadURL: URL?
    }

    enum CheckResult: Sendable {
        case upToDate
        case available(Release)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the latest release when it is newer than the running build.
    static func checkForUpdate() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return .failed(String(localized: "update.error.url",
                                     defaultValue: "Repository URL không hợp lệ.")) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed(String(localized: "update.error.response",
                                  defaultValue: "Phản hồi cập nhật không hợp lệ."))
        }
        guard http.statusCode == 200 else {
            return .failed(String(localized: "update.error.http",
                                  defaultValue: "GitHub trả HTTP \(http.statusCode)."))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let tag = dict["tag_name"] as? String,
              let htmlURL = (dict["html_url"] as? String).flatMap(URL.init(string:))
        else { return .failed(String(localized: "update.error.metadata",
                                     defaultValue: "Không đọc được metadata bản phát hành.")) }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let downloadURL = preferredAssetURL(from: dict)
        return isNewer(latest, than: currentVersion)
            ? .available(Release(version: latest, url: htmlURL, downloadURL: downloadURL)) : .upToDate
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

    private static func preferredAssetURL(from release: [String: Any]) -> URL? {
        guard let assets = release["assets"] as? [[String: Any]] else { return nil }
        let preferred = assets.first { asset in
            guard let name = asset["name"] as? String else { return false }
            let lower = name.lowercased()
            return lower.hasSuffix(".dmg") || lower.hasSuffix(".zip")
        } ?? assets.first
        return (preferred?["browser_download_url"] as? String).flatMap(URL.init(string:))
    }
}
