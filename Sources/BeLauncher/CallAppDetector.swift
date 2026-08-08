import AppKit
import BeLauncherCore
import CoreGraphics

@MainActor
final class CallAppDetector: ObservableObject {
    @Published private(set) var suggestedSource: CallAudioSource?
    @Published private(set) var suggestedAppName: String?
    @Published private(set) var likelyInCall = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    var onUpdate: () -> Void = {}

    func start() {
        guard observer == nil else { refresh(); return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let known = NSWorkspace.shared.runningApplications.filter { app in
            let id = app.bundleIdentifier ?? ""
            return CallAudioSource.zoom.bundleIdentifiers.contains(id)
                || CallAudioSource.teams.bundleIdentifiers.contains(id)
                || CallAudioSource.meet.bundleIdentifiers.contains(id)
        }
        var candidates = [frontmost].compactMap { $0 }
        for app in known where !candidates.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            candidates.append(app)
        }

        // The call window can remain visible while another app is briefly frontmost. Inspect all
        // known conferencing processes, but keep the frontmost app as the non-recording suggestion
        // when no active call window is identifiable.
        var fallback: (CallAudioSource, String)?
        for app in candidates {
            guard let source = source(for: app) else { continue }
            let name = app.localizedName ?? source.title
            if windowLooksLikeCall(app.processIdentifier, source: source) {
                update(source: source, name: name, active: true)
                return
            }
            if app.processIdentifier == frontmost?.processIdentifier {
                fallback = (source, name)
            }
        }
        if let fallback {
            update(source: fallback.0, name: fallback.1, active: false)
        } else {
            update(source: nil, name: nil, active: false)
        }
    }

    private func source(for app: NSRunningApplication) -> CallAudioSource? {
        let bundleID = app.bundleIdentifier ?? ""
        if CallAudioSource.zoom.bundleIdentifiers.contains(bundleID) { return .zoom }
        if CallAudioSource.teams.bundleIdentifiers.contains(bundleID) { return .teams }
        if CallAudioSource.meet.bundleIdentifiers.contains(bundleID) {
            return browserLooksLikeCall(app.processIdentifier) ? .meet : nil
        }
        return nil
    }

    private func update(source: CallAudioSource?, name: String?, active: Bool) {
        guard suggestedSource != source || suggestedAppName != name || likelyInCall != active else { return }
        suggestedSource = source
        suggestedAppName = name
        likelyInCall = active
        onUpdate()
    }

    private func browserLooksLikeCall(_ pid: pid_t) -> Bool {
        windowNames(for: pid).contains { name in
            let value = name.lowercased()
            return value.contains("google meet") || value.contains("meet.google.com")
        }
    }

    private func windowLooksLikeCall(_ pid: pid_t, source: CallAudioSource) -> Bool {
        let names = windowNames(for: pid).map { $0.lowercased() }
        if source == .meet { return browserLooksLikeCall(pid) }
        return names.contains { name in
            ["zoom meeting", "zoom webinar", "meeting", "call", "reunion"].contains {
                name.contains($0)
            }
        }
    }

    private func windowNames(for pid: pid_t) -> [String] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return entry[kCGWindowName as String] as? String
        }
    }
}
