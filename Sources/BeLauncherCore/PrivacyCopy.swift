import Foundation

/// The words the privacy and brain panels say, kept out of the views.
///
/// Same reason `BrainSetupCopy` exists: a sentence that only lives inside a `View` body cannot be
/// read by a test, so it drifts. These sentences drift worse than most, because two of them carry
/// the only irreversible action in the app. "Se borra para siempre" has to be right the first
/// time — nobody gets a second reading of a delete that already happened.
///
/// The brain counts live here too, next to the pause and the exclusions, because they answer the
/// same question the privacy panel does: what does this thing hold about me. Everything here is
/// pure — strings and dates in, strings out, no store, no clock of its own.
public enum PrivacyCopy {

    // MARK: - Pausar

    public static var pauseTitle: String { L("Pause") }
    public static var pauseExplanation: String {
        L("While it is paused nothing is saved: not what you open, not what you copy, not who you talk to. Everything from before stays where it was.")
    }

    /// How long a pause lasts, as the four answers people actually give.
    ///
    /// A date picker would cover all of them and be used by nobody: the moment you need a pause is
    /// the moment somebody is walking into your office, and a form is the wrong thing to hand
    /// somebody in a hurry.
    public enum PauseChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
        case quarterHour
        case hour
        case tomorrow
        case untilIResume

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .quarterHour: L("15 minutes")
            case .hour: L("1 hour")
            case .tomorrow: L("Until tomorrow")
            case .untilIResume: L("Until I turn it back on")
            }
        }

        /// An open-ended pause is a different state, not a very long timer: nothing should ever
        /// turn capture back on for somebody who did not ask for a moment in particular.
        public var reason: Privacy.PauseReason {
            self == .untilIResume ? .byHand : .untilLater
        }

        /// When capture comes back on its own. `nil` means it does not.
        public func until(from now: Date = .now, calendar: Calendar = .current) -> Date? {
            switch self {
            case .quarterHour: return now.addingTimeInterval(15 * 60)
            case .hour: return now.addingTimeInterval(3600)
            case .tomorrow:
                // Eight in the morning, not midnight. Midnight breaks the promise for exactly the
                // person most likely to use this option: pause at 23:00 saying "hasta mañana" and
                // a literal reading gives you a one-hour pause that ends while you are asleep.
                let nextDay = calendar.startOfDay(for: now.addingTimeInterval(24 * 3600))
                return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: nextDay) ?? nextDay
            case .untilIResume: return nil
            }
        }
    }

    /// What the panel says at the top, so the answer is there before anybody reads a control.
    public struct Banner: Sendable, Equatable {
        public let isPaused: Bool
        public let headline: String
        public let detail: String
        /// Empty when there is nothing for a person to turn back on.
        public let resumeTitle: String
    }

    public static func banner(for state: Privacy.State, at now: Date = .now) -> Banner {
        guard !state.isCapturing(at: now) else {
            return Banner(
                isPaused: false,
                headline: L("It is capturing."),
                detail: L("It saves what you open and what you copy so it can answer you later. All of it stays on this Mac."),
                resumeTitle: ""
            )
        }
        switch state.reason {
        case .untilLater:
            let detail = state.until.map { L("Back on its own in %@.", remaining(until: $0, at: now)) }
                ?? L("Back on its own in a while.")
            return Banner(isPaused: true, headline: L("Paused. Nothing is being saved."),
                          detail: detail, resumeTitle: L("Resume now"))

        // `sharingScreen` used to have its own wording here — "vuelve sola cuando dejes de
        // compartir", with no Resume button, because the app was going to notice by itself. It
        // cannot. Measured on this Mac (macOS 26.6, SDK 26.5): `CGDisplayIsCaptured` is marked
        // unavailable, "No longer supported"; `CGSessionCopyCurrentDictionary` returns thirteen
        // keys and not one of them mentions capture or sharing; ScreenCaptureKit only describes
        // what *this* app may capture, never who is capturing us; and nothing in the whole SDK
        // answers the question. The only thing left is guessing from a list of conference apps,
        // which cannot see a screen shared from a browser tab — Meet, a Slack huddle, Whereby —
        // so it would be off exactly when somebody believed it was on.
        //
        // So the promise is gone rather than half kept, case included. A database written by an
        // older build stored the raw string, and the reason parser falls back to "not paused", so
        // nobody is trapped in a pause they cannot end.
        case .byHand, .notPaused:
            return Banner(isPaused: true, headline: L("Paused. Nothing is being saved."),
                          detail: L("It stays like this until you turn it back on."),
                          resumeTitle: L("Resume"))
        }
    }

    /// What the menu bar shows while capture is off. `nil` means show nothing.
    ///
    /// This exists because a pause that is only visible inside the panel that set it is worse than
    /// no pause at all: you pause for a call, close the window, and three days later you are still
    /// paused and believing otherwise. The words are there rather than an icon alone — a second
    /// grey glyph in a menu bar is invisible, and this one has to be read.
    public static func menuBarTitle(for state: Privacy.State, at now: Date = .now) -> String? {
        guard !state.isCapturing(at: now) else { return nil }
        if state.reason == .untilLater, let until = state.until {
            return L("Paused") + " · " + shortRemaining(until: until, at: now)
        }
        return L("Paused")
    }

    public static func menuBarTooltip(for state: Privacy.State, at now: Date = .now) -> String {
        let banner = banner(for: state, at: now)
        return banner.headline + " " + banner.detail
    }

    /// "47 minutes", "1 hour and 5 minutes". Written out because this sits inside a sentence.
    ///
    /// Assembled from pieces rather than from one string per case: the two languages agree on the
    /// shape here (number, unit, joiner, number, unit), and eight near-identical catalog entries
    /// would be eight chances for one of them to drift.
    public static func remaining(until: Date, at now: Date = .now) -> String {
        let seconds = until.timeIntervalSince(now)
        guard seconds > 60 else { return L("less than a minute") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? L("1 minute") : L("%@ minutes", String(minutes)) }
        let hours = minutes / 60
        let rest = minutes % 60
        let hoursText = hours == 1 ? L("1 hour") : L("%@ hours", String(hours))
        guard rest > 0 else { return hoursText }
        let restText = rest == 1 ? L("1 minute") : L("%@ minutes", String(rest))
        return L("%1$@ and %2$@", hoursText, restText)
    }

    /// The same thing squeezed into a menu bar, where every character costs screen.
    public static func shortRemaining(until: Date, at now: Date = .now) -> String {
        let seconds = until.timeIntervalSince(now)
        guard seconds > 60 else { return L("<1 min") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L("%@ min", String(minutes)) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L("%@ h", String(hours)) : L("%1$@ h %2$@ min", String(hours), String(rest))
    }

    public static var resumeExplanation: String {
        L("Resuming brings nothing back from the pause. It was never saved; it is nowhere.")
    }

    // MARK: - Excluir

    public static var exclusionsTitle: String { L("What it never looks at") }
    public static var exclusionsExplanation: String {
        L("Not the name, not the content. If an app or a site is on this list, as far as BeLauncher is concerned it does not exist.")
    }

    /// Shown, not hidden. A list that arrives full is the only way somebody can tell in five
    /// seconds that the app already thought about this; an empty list asks them to imagine every
    /// bank and every password manager before the first one goes in.
    public static var defaultsExplanation: String {
        L("These come set from the factory. You can remove them, but they are there because your password manager and your bank are not things anybody wants remembered.")
    }

    public static var appsEmpty: String { L("No app is excluded. Everything you open counts.") }
    public static var domainsEmpty: String { L("No domain is excluded. Every site you visit counts.") }
    public static var addAppPlaceholder: String { L("App name or its identifier") }
    /// An example rather than a label, and it changes with the language: a Spanish speaker reading
    /// "yourbank.com" has to translate the instruction in their head before they can follow it.
    public static var addDomainPlaceholder: String { L("yourbank.com") }

    /// Bundle identifiers read like machine parts. The list is for a person, so the row says
    /// "1Password" and keeps the identifier as the small print.
    public static func appName(_ stored: String) -> String {
        let known: [String: String] = [
            "com.1password.1password": "1Password",
            "com.agilebits.onepassword7": "1Password 7",
            "com.bitwarden.desktop": "Bitwarden",
            "com.apple.keychainaccess": L("Keychain Access"),
            "com.dashlane.dashlane": "Dashlane",
            "in.sinew.enpass-desktop": "Enpass",
            "com.apple.passwords": L("Apple Passwords"),
        ]
        if let name = known[stored.lowercased()] { return name }
        guard stored.contains("."), !stored.contains(" ") else {
            return stored.prefix(1).uppercased() + stored.dropFirst()
        }
        let tail = stored.split(separator: ".").last.map(String.init) ?? stored
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    /// Turns whatever somebody pasted into the thing the matcher actually compares against.
    ///
    /// The matcher looks for a substring inside the URL, so a pasted `https://www.Banco.com/login`
    /// would only ever match that exact page. Trimming it to `banco.com` is the difference between
    /// excluding a bank and excluding one screen of it.
    public static func normalisedDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text.isEmpty ? nil : text
    }

    /// What is wrong with what they typed, or `nil` when nothing is.
    public static func problem(withDomain input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(" ") {
            return L("A domain has no spaces in it. Write something like “%@”.", addDomainPlaceholder)
        }
        return normalisedDomain(trimmed) == nil
            ? L("That does not look like a domain. Write something like “%@”.", addDomainPlaceholder)
            : nil
    }

    public static func problem(withApp input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count < 2
            ? L("Write the app's name as it appears in the Dock, or its identifier.")
            : nil
    }

    /// Said when the first hand-picked exclusion is added, because that is the moment the list
    /// stops being the factory one and starts being theirs.
    public static var defaultsKept: String {
        L("The factory ones are still on the list: adding your own does not remove them.")
    }

    // MARK: - Olvidar

    public static var forgetTitle: String { L("Forget a stretch of time") }
    public static var forgetExplanation: String {
        L("It really deletes what was saved in that period. No trash, no undo, no copy: it is the one thing in this app that cannot be recovered.")
    }

    public enum ForgetChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
        case lastHour
        case today
        case thisAfternoon
        case range

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .lastHour: L("The last hour")
            case .today: L("Today")
            case .thisAfternoon: L("This afternoon")
            case .range: L("A specific stretch")
            }
        }

        /// The period this covers. `nil` for `.range`, which the person picks with two dates —
        /// there is no sensible guess to make there and guessing is what this screen cannot do.
        public func period(now: Date = .now, calendar: Calendar = .current) -> Privacy.Period? {
            switch self {
            case .lastHour: Privacy.Period.lastHour(now: now)
            case .today: Privacy.Period.today(now: now, calendar: calendar)
            case .thisAfternoon: Privacy.Period.afternoon(of: now, calendar: calendar)
            case .range: nil
            }
        }
    }

    /// The last thing between somebody and a delete that cannot be undone.
    public struct Confirmation: Sendable, Equatable {
        /// False when there is nothing there. The button is not offered, so a confirmed delete
        /// always deletes something the person was told about.
        public let canProceed: Bool
        public let title: String
        public let message: String
        /// Names the number, so agreeing to "olvidar 3 cosas" cannot quietly be 900.
        public let confirmTitle: String
        public let cancelTitle: String
        /// Always true. The key that answers a dialog without reading it must be the safe one.
        public let cancelIsDefault: Bool
    }

    /// What is inside the period, in words somebody outside this codebase can picture.
    ///
    /// `Privacy.Forgetting.warning` already says this, but it says "del grafo", and the graph is
    /// our word for it, not theirs. Nobody should have to know the shape of our storage to agree
    /// to a delete.
    public static func breakdown(_ forgetting: Privacy.Forgetting) -> String {
        var parts: [String] = []
        if forgetting.passages > 0 {
            parts.append(forgetting.passages == 1
                ? L("1 fragment")
                : L("%@ fragments", String(forgetting.passages)))
        }
        if forgetting.clips > 0 {
            parts.append(forgetting.clips == 1
                ? L("1 clipboard copy")
                : L("%@ clipboard copies", String(forgetting.clips)))
        }
        if forgetting.nodes > 0 {
            parts.append(forgetting.nodes == 1
                ? L("1 thing you were working on")
                : L("%@ things you were working on", String(forgetting.nodes)))
        }
        guard !parts.isEmpty else { return L("Nothing was saved in that stretch.") }
        if parts.count == 1 { return L("Deleted for good: %@.", parts[0]) }
        let last = parts.removeLast()
        return L("Deleted for good: %1$@ and %2$@.", parts.joined(separator: ", "), last)
    }

    public static func confirmation(period label: String,
                                    forgetting: Privacy.Forgetting) -> Confirmation {
        guard !forgetting.isEmpty else {
            return Confirmation(
                canProceed: false,
                title: L("Nothing is saved under “%@”.", label.lowercased()),
                message: L("There is nothing to delete, so there is nothing to confirm."),
                confirmTitle: "", cancelTitle: L("Got it"), cancelIsDefault: true
            )
        }
        let count = forgetting.total
        return Confirmation(
            canProceed: true,
            title: L("Forget “%@”?", label.lowercased()),
            message: breakdown(forgetting) + " " + L("This cannot be undone."),
            confirmTitle: count == 1 ? L("Forget 1 thing") : L("Forget %@ things", String(count)),
            cancelTitle: L("Cancel"),
            cancelIsDefault: true
        )
    }

    public static func forgotten(_ forgetting: Privacy.Forgetting, period label: String) -> String {
        if forgetting.isEmpty {
            return L("Nothing was saved under “%@”.", label.lowercased())
        }
        return forgetting.total == 1
            ? L("Forgotten: 1 thing from “%@”. It is nowhere now.", label.lowercased())
            : L("Forgotten: %1$@ things from “%2$@”. They are nowhere now.",
                String(forgetting.total), label.lowercased())
    }

    /// When the counts do not drop to zero after deleting, which means the database refused part
    /// of it. Silence here would leave somebody believing something was erased.
    public static func forgetFailed(left: Int) -> String {
        left == 1
            ? L("Part of it went, but 1 thing is still there. Quit BeLauncher, open it again and repeat: it is almost always something that was mid-write.")
            : L("Part of it went, but %@ things are still there. Quit BeLauncher, open it again and repeat: it is almost always something that was mid-write.", String(left))
    }

    public static var counting: String { L("Counting what is in that stretch…") }
    public static var rangeStart: String { L("From") }
    public static var rangeEnd: String { L("To") }
    public static var rangeBackwards: String { L("The start date comes before the end date.") }

    // MARK: - Lo que el cerebro tiene dentro

    /// The numbers, so it stops being a black box.
    ///
    /// A person who can see "1.240 fragmentos" can compare it against what they know they have
    /// written. A person who can only see "listo" has to take the app's word for it, and nobody
    /// hands their working memory to something they have to take at its word.
    public enum Brain {

        public struct Card: Sendable, Equatable, Identifiable {
            public let id: String
            public let value: String
            public let label: String
            /// One line under the number, saying what it is a count of.
            public let hint: String

            public init(id: String, value: String, label: String, hint: String) {
                self.id = id
                self.value = value
                self.label = label
                self.hint = hint
            }
        }

        public static func cards(passages: Int, vectorised: Int, episodes: Int,
                                 entities: Int, clips: Int) -> [Card] {
            [
                Card(id: "passages", value: BrainSetupCopy.number(passages),
                     label: passages == 1 ? L("fragment") : L("fragments"),
                     hint: L("Pieces of your notes and your work, searchable one by one.")),
                Card(id: "vectorised", value: BrainSetupCopy.number(vectorised),
                     label: L("understand what you mean"),
                     hint: L("The rest are only found by their exact words.")),
                Card(id: "episodes", value: BrainSetupCopy.number(episodes),
                     label: episodes == 1 ? L("stretch of work") : L("stretches of work"),
                     hint: L("Grouped sessions: what you did in one go, uninterrupted.")),
                Card(id: "entities", value: BrainSetupCopy.number(entities),
                     label: entities == 1 ? L("name it knows") : L("names it knows"),
                     hint: L("People, companies and projects it can recognise.")),
                Card(id: "clips", value: BrainSetupCopy.number(clips),
                     label: clips == 1 ? L("saved copy") : L("saved copies"),
                     hint: L("What you copied and is still in the history.")),
            ]
        }

        public static var emptyHeadline: String { L("There is nothing in it yet.") }
        public static var emptyDetail: String {
            L("The moment you save a note or copy a piece of text, it shows up here and can be counted. Not one number on this screen is an estimate.")
        }

        public static var counting: String { L("Counting what is stored…") }

        /// Never a bare "error". It says what did not happen and what to do next, because the only
        /// useful failure message is one that ends with an action.
        public static func failed(_ reason: String) -> String {
            L("The brain's status could not be read: %@. Press “Refresh”; if it stays like this, export the diagnostic from Data and send it to us.", reason)
        }

        public static var localLine: String { L("All of this is worked out and kept on this Mac.") }
        public static var remoteLine: String {
            L("The model that understands meaning lives on a server: the text you search leaves this Mac to reach it. Install a local one if you would rather nothing left.")
        }
    }
}
