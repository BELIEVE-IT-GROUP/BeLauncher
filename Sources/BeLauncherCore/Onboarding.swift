import Foundation

/// What the app needs, why, and what it does with it — said once, up front, in one place.
///
/// "Just in time" permissions sounded principled and were unusable: the app never told anyone what
/// it could do, so nobody ever hit the moment that would have asked. The person who bought a
/// launcher to move faster ended up with a launcher that quietly did less, and no way to find out
/// why. Explaining everything at the start and letting the person switch each one on is not more
/// intrusive — it is the version where they are actually deciding.
public enum Onboarding {

    public struct Capability: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case accessibility
            case automation
            case screen
            case calendar
            case reminders
            case contacts
            case photos
            case notifications
            case microphone
            case fullDiskAccess
            case clipboard
            case updates
            case launchAtLogin
        }

        public let id: String
        public let kind: Kind
        public let title: String
        /// What the person gets. Never the name of the API.
        public let unlocks: String
        /// What is actually accessed, in plain words.
        public let accesses: String
        /// What still works if they say no.
        public let ifYouSayNo: String
        public let symbol: String
        /// Whether macOS itself will ask. The rest are just our own settings.
        public let isSystemPermission: Bool
        /// Recommended on, because the app is noticeably worse without it.
        public let recommended: Bool

        public init(kind: Kind, title: String, unlocks: String, accesses: String,
                    ifYouSayNo: String, symbol: String, isSystemPermission: Bool,
                    recommended: Bool) {
            self.id = kind.rawValue
            self.kind = kind
            self.title = title
            self.unlocks = unlocks
            self.accesses = accesses
            self.ifYouSayNo = ifYouSayNo
            self.symbol = symbol
            self.isSystemPermission = isSystemPermission
            self.recommended = recommended
        }
    }

    /// Rebuilt on every read rather than stored, so a language chosen after launch is reflected
    /// here. Eight structs, once per screen.
    public static var capabilities: [Capability] {
        [
            .init(kind: .clipboard,
                  title: L("Clipboard history"),
                  unlocks: L("Get back anything you copied, with ⌥C. Text, images and files."),
                  accesses: L("What you copy, stored on your Mac. Never what you copy out of a password manager, and never anything shaped like a key or a token: that is thrown away before it is written."),
                  ifYouSayNo: L("The launcher, the snippets and everything else carry on. You only lose the history."),
                  symbol: "doc.on.clipboard", isSystemPermission: false, recommended: true),

            .init(kind: .fullDiskAccess,
                  title: L("Local Mail, Messages and Notes"),
                  unlocks: L("Let your Brain connect relevant evidence from Apple Mail, Messages and Notes to the original item on this Mac."),
                  accesses: L("Their protected local databases. BeLauncher reads them on this Mac, keeps only relevant text plus a link to the original, and never uploads them."),
                  ifYouSayNo: L("Apps, files, clipboard, manual notes and every launcher command still work. These three sources remain disconnected."),
                  symbol: "externaldrive.badge.checkmark", isSystemPermission: true,
                  recommended: true),

            .init(kind: .accessibility,
                  title: L("Accessibility"),
                  unlocks: L("Pasting straight into the app you were in, and moving windows around (left half, full screen, across two displays)."),
                  accesses: L("macOS only lets an app press ⌘V in another app, or move its window, with this permission. BeLauncher uses it for nothing else: it does not read your screen, your keystrokes, or the contents of other apps."),
                  ifYouSayNo: L("You copy with Enter and paste yourself with ⌘V. Window management does not work."),
                  symbol: "accessibility", isSystemPermission: true, recommended: true),

            .init(kind: .automation,
                  title: L("Automation"),
                  unlocks: L("System commands and flows: silence notifications, put the Mac to sleep, dark mode, empty the trash, eject disks, run your macOS Shortcuts. Without it, a flow like “focus” runs and nothing happens."),
                  accesses: L("macOS asks for this because it technically allows asking other apps for things. BeLauncher only asks “System Events” and the Finder, and only when you run a command. It does not read the contents of your apps or drive them on its own."),
                  ifYouSayNo: L("Everything else works. System commands and the flow steps that touch the Mac fail with a warning instead of failing quietly."),
                  symbol: "gearshape.2", isSystemPermission: true, recommended: true),

            .init(kind: .screen,
                  title: L("Read the screen"),
                  unlocks: L("Press ⌥⇧Space with anything in front of you — an error, an invoice, an email, a table — and it offers the three sensible things to do with it. No copying, no switching windows, no explaining where it came from."),
                  accesses: L("Almost never the screen: it first tries to read whatever you have selected, which needs none of this. Only when there is no selection does it take a picture of the screen, read it **on your Mac** with Apple's text recognition, and throw it away. No image is stored and nothing is uploaded. What it recognises goes to the model you chose, exactly as if you had typed it. Nothing is captured unless you press the shortcut."),
                  ifYouSayNo: L("It still works with whatever you have selected and with the clipboard. You only lose the “I can see it but I cannot select it” case."),
                  symbol: "rectangle.dashed.badge.record", isSystemPermission: true,
                  recommended: false),

            .init(kind: .calendar,
                  title: L("Calendar"),
                  unlocks: L("“Prepare me for the meeting with Acme” gathers what you know about them and crosses it with what is on your calendar today."),
                  accesses: L("Only the titles and times of your events, read at that moment and never stored or sent anywhere."),
                  ifYouSayNo: L("Preparing for a meeting still works, but you have to type who it is with."),
                  symbol: "calendar", isSystemPermission: true, recommended: false),

            .init(kind: .reminders,
                  title: L("Reminders"),
                  unlocks: L("Search pending reminders from the launcher and Brain."),
                  accesses: L("Only reminder titles, lists and due dates on this Mac."),
                  ifYouSayNo: L("Everything else works; reminders stay disconnected."),
                  symbol: "checklist", isSystemPermission: true, recommended: false),

            .init(kind: .contacts,
                  title: L("Contacts"),
                  unlocks: L("Find a person, email or phone number without leaving the launcher."),
                  accesses: L("Names and contact details only when you search."),
                  ifYouSayNo: L("Everything else works; contacts stay disconnected."),
                  symbol: "person.crop.circle", isSystemPermission: true, recommended: false),

            .init(kind: .photos,
                  title: L("Photos"),
                  unlocks: L("Find local photos and open them in Photos."),
                  accesses: L("Photo metadata only; originals are not copied into the Brain."),
                  ifYouSayNo: L("Everything else works; Photos stays disconnected."),
                  symbol: "photo", isSystemPermission: true, recommended: false),

            .init(kind: .notifications,
                  title: L("Notifications"),
                  unlocks: L("Flow timers tell you when they finish. Without this, a 50-minute focus block ends in silence."),
                  accesses: L("Nothing. It only allows showing a notice."),
                  ifYouSayNo: L("Flows work; timers do not announce themselves."),
                  symbol: "bell", isSystemPermission: true, recommended: false),

            .init(kind: .microphone,
                  title: L("Voice notes and dictation"),
                  unlocks: L("Record a voice note or dictate into any app with a global shortcut. Audio stays on this Mac."),
                  accesses: L("The microphone only while you explicitly record or dictate. There is no background listening."),
                  ifYouSayNo: L("The launcher and Brain work normally. Voice notes and dictation stay off."),
                  symbol: "mic", isSystemPermission: true, recommended: false),

            .init(kind: .launchAtLogin,
                  title: L("Open at login"),
                  unlocks: L("The global shortcut works from the moment you turn on the Mac, without opening anything."),
                  accesses: L("Nothing. It is a macOS setting."),
                  ifYouSayNo: L("You will have to open BeLauncher by hand every day."),
                  symbol: "power", isSystemPermission: false, recommended: true),

            .init(kind: .updates,
                  title: L("Check for updates"),
                  unlocks: L("It tells you in the menu bar when there is a new version and installs it with one button."),
                  accesses: L("One request to our download server to read a version number. It carries no idea who you are, what you use, or anything from your Mac."),
                  ifYouSayNo: L("It never touches the network. You find out about new versions wherever you like."),
                  symbol: "arrow.down.circle", isSystemPermission: false, recommended: true),
        ]
    }

    /// The promise, stated where the person is deciding — not buried in a privacy policy.
    public static var privacy: String {
        [
            L("BeLauncher has no account, no analytics, no telemetry, and no server where your data lives."),
            L("What you type, what you copy and what you keep in your brain stay on this Mac, in one database and one folder of Markdown files you can open, copy or delete yourself."),
            L("Only three things ever reach the network, and you decide all three: activating your licence (once), checking whether there is a new version, and AI requests if you pick a cloud model. Those go from your Mac straight to the provider with your key: they do not pass through us."),
            L("With a local model (Ollama, LM Studio), not even that."),
        ].joined(separator: "\n\n")
    }

    /// The five things worth knowing on day one. Not fifty shortcuts: five.
    public static var firstThings: [(keys: String, does: String)] {
        [
            ("⇧⌘Space", L("Opens BeLauncher. Start typing to search apps, files and everything else.")),
            ("⌥C", L("Your clipboard history.")),
            ("↩", L("Does the obvious thing with whatever is selected: open the app, copy the result.")),
            ("⌘K", L("Everything else you can do with it: reveal in Finder, ask the AI for something, give it an alias.")),
            ("Tab", L("Completes what you are typing.")),
        ]
    }

    /// Five things to try, in the order that makes the product click.
    ///
    /// The typed examples are translated too, and that is the point of translating them: an example
    /// a Spanish speaker cannot type is worse than no example, and "recordar que…" is a phrase the
    /// launcher genuinely listens for. Every string in the left column has to be one the intent
    /// tables in `Phrases` actually recognise — if one of them stops working, this list is lying.
    public static var tryThis: [(type: String, andSee: String)] {
        [
            ("2+2*10", L("Works it out as you type. Enter copies the result.")),
            ("10 km to mi", L("Converts units, currencies and time zones the same way.")),
            (L("f report"), L("Finds files by name across your whole Mac.")),
            (L("focus"), L("A mission: it silences everything and starts a 50-minute block. It shows you the plan before doing anything.")),
            (L("remember we raised the price to 90"), L("Offers to keep it in your brain. You confirm.")),
        ]
    }
}
