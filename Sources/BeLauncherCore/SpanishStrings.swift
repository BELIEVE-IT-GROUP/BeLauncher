import Foundation

/// The Spanish translation of every string the app shows.
///
/// Written as Swift rather than as a `.strings` or `.xcstrings` resource, and that was a decision
/// rather than a shortcut. String Catalogs are compiled by `xcstringstool`, which is part of Xcode
/// and not of a plain `swift build`; `.lproj` resources need `defaultLocalization` and a `resources:`
/// declaration in `Package.swift`, plus a bundle copied into the hand-rolled `.app`. Both were
/// checked. A Swift table needs none of that, works identically under `swift test`, cannot go
/// missing at runtime, and can be walked by a test that fails the build when a call site has no
/// translation — which is the only thing that keeps an app from being half translated.
///
/// The keys are the English strings themselves. There is no identifier file to drift out of sync,
/// and a string with no entry here degrades to readable English rather than to `brain.empty.title`.
///
/// Split into several tables because a single dictionary literal of this size makes the Swift type
/// checker take minutes over it.
enum SpanishStrings {
    static let table: [String: String] = {
        var merged: [String: String] = [:]
        for chunk in [brain, setup, onboarding, privacy, settings, results, system, verbs, errors] {
            merged.merge(chunk) { _, new in new }
        }
        return merged
    }()
}
