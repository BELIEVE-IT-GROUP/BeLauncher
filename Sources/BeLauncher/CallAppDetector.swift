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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            update(source: nil, name: nil, active: false); return
        }
        let bundleID = app.bundleIdentifier ?? ""
        let source: CallAudioSource?
        if CallAudioSource.zoom.bundleIdentifiers.contains(bundleID) { source = .zoom }
        else if CallAudioSource.teams.bundleIdentifiers.contains(bundleID) { source = .teams }
        else if CallAudioSource.meet.bundleIdentifiers.contains(bundleID) {
            source = browserLooksLikeCall(app.processIdentifier) ? .meet : nil
        } else { source = nil }
        let name = source == nil ? nil : (app.localizedName ?? source?.title)
        let active = source != nil && windowLooksLikeCall(app.processIdentifier, source: source!)
        update(source: source, name: name, active: active)
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
