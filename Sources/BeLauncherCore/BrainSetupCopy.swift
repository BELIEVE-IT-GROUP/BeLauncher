import Foundation

/// The words and the verdicts the brain screens show, kept out of the views.
///
/// Two things were being decided inside SwiftUI bodies and neither of them belongs there. The
/// first is the wording: "conectado" used to be printed next to a green dot the moment a config
/// file mentioned BeLauncher, which is a claim the app could not back. The second is the verdict
/// itself — deciding whether a set of health checks reads as working, broken or simply unchecked
/// is a rule, and a rule that only exists inside a `View` cannot be tested, so it drifts.
///
/// Everything here is pure: strings in, strings out, no store, no process, no clock.
public enum BrainSetupCopy {

    // MARK: - Numbers, so it stops being a black box

    /// What the brain has, said in numbers a person can check against reality.
    public struct IndexReadout: Sendable, Equatable {
        /// The single line that answers "does this thing have anything in it".
        public let headline: String
        /// What is left to do, or why nothing is.
        public let detail: String
        /// Which model answers, and whether the text leaves the Mac to reach it.
        public let engineLine: String
        public let passages: Int
        public let vectorised: Int
        /// 0…1. Only meaningful when there is something indexed.
        public let percent: Double
        /// True when meaning search is not available yet. Drives whether the setup screen shows.
        public let needsModel: Bool
        /// True when every passage already carries a vector.
        public let isComplete: Bool
    }

    public static func readout(passages: Int, vectorised: Int,
                               engine: String?, isLocal: Bool) -> IndexReadout {
        let percent = passages == 0 ? 0 : min(1, Double(vectorised) / Double(passages))
        let complete = passages > 0 && vectorised >= passages

        let headline: String
        if passages == 0 {
            headline = L("Nothing is indexed yet.")
        } else if passages == 1 {
            headline = L("One fragment of your notes, your work and your clipboard.")
        } else {
            headline = L("%@ fragments of your notes, your work and your clipboard.", number(passages))
        }

        let detail: String
        if passages == 0 {
            detail = L("The moment you save something or copy a piece of text, it shows up here.")
        } else if engine == nil {
            detail = L("They are searched by exact words. None of them understands meaning yet: the model is missing.")
        } else if complete {
            detail = L("All of them understand meaning.")
        } else if vectorised == 0 {
            detail = L("None of them understands meaning yet. Start processing and this number climbs.")
        } else {
            detail = L("%1$@ understand meaning. %2$@ still to process.",
                       number(vectorised), number(passages - vectorised))
        }

        let engineLine: String
        if let engine {
            engineLine = isLocal
                ? L("Model %@, running on your Mac. Nothing goes to the internet.", engine)
                : L("Model %@, on a server. The text you search leaves your Mac to reach it.", engine)
        } else {
            engineLine = L("No model installed.") + " " + ModelInstall.wordSearchStillWorks
        }

        return IndexReadout(headline: headline, detail: detail, engineLine: engineLine,
                            passages: passages, vectorised: vectorised, percent: percent,
                            needsModel: engine == nil, isComplete: complete)
    }

    /// Grouping fixed per language rather than taken from the system locale: the same numbers have
    /// to read the same way in a screenshot, in a support ticket and in a test running on a machine
    /// set to anything. English groups with commas, Spanish with points, and neither depends on
    /// which country the Mac thinks it is in.
    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = Loc.language == .spanish ? "." : ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Rebuilding the index

    public static var rebuildTitle: String { L("Rebuild the index") }
    public static var rebuildExplanation: String {
        L("Cuts everything again and reprocesses it from scratch. It takes a while, it deletes no notes, and it is only worth doing if the results stop making sense.")
    }
    public static var rebuildRunning: String { L("Rebuilding the index…") }

    public static func rebuildFinished(passages: Int, vectorised: Int) -> String {
        L("Index rebuilt: %1$@ fragments, %2$@ of them with meaning.",
          number(passages), number(vectorised))
    }

    // MARK: - The setup screen

    public static var setupTitle: String { L("Let it understand what you mean") }

    /// The reason, with the example that makes it obvious. A number of gigabytes without a reason
    /// is a request; with the example it is an offer.
    public static var setupWhy: String {
        L("Right now it finds things by the words you type. With this model it also finds them by what they mean: you ask “what do we charge for Pro” and up comes “the base price is 1000 EUR”, without a single word in common.")
    }

    public static var setupCost: String { ModelInstall.pitch }
    public static var setupSkip: String { L("Carry on without it") }
    public static var setupLater: String { L("You can add it later from Settings, under “My brain”.") }
    /// Said while the bytes are moving, because the honest answer to "do I have to wait" is no.
    public static var setupKeepUsing: String {
        L("Keep using BeLauncher while it downloads. We will tell you here when it is done.")
    }
    public static var setupDone: String { L("Done. It searches by meaning now.") }

    /// The two ways to get Ollama, worded so neither one runs anything behind the person's back.
    public static var installByHand: String { L("Download Ollama") }
    public static var installByHomebrew: String { L("Install with Homebrew") }
    public static var installExplanation: String {
        L("The model comes down through Ollama, which is free and also stays on your Mac. Pick how to install it: nothing runs until you press something.")
    }

    // MARK: - Whether "conectado" means anything

    /// Three levels, and `unknown` is one of them on purpose. Before this existed the panel had
    /// only two states and defaulted to the good one, so an assistant that answered nothing still
    /// showed green. Never having checked is now its own answer.
    public enum Level: String, Sendable, Equatable {
        case unknown
        case working
        case broken
    }

    public struct Verdict: Sendable, Equatable {
        public let level: Level
        /// The pill text. Short enough to sit next to a client name.
        public let label: String
        /// One sentence naming what failed. Empty when nothing did.
        public let headline: String
        /// What to do about it. Empty when there is nothing to do.
        public let whatToDo: String
    }

    public static func verdict(for report: MCPHealth.Report?) -> Verdict {
        guard let report else { return neverChecked }
        if report.isConnected {
            return Verdict(level: .working, label: L("answers with data"),
                           headline: L("All five steps pass: a real call brings content back."),
                           whatToDo: "")
        }
        guard let failure = report.firstFailure else { return neverChecked }
        return Verdict(level: .broken, label: shortFailure(failure.step),
                       headline: failure.outcome.reason ?? failure.step.title,
                       whatToDo: whatToDo(about: failure.step))
    }

    static var neverChecked: Verdict {
        Verdict(level: .unknown, label: L("unchecked"),
                headline: L("The connection has not been tested yet."),
                whatToDo: L("Press “%@” and the five steps run.", checkButton))
    }

    /// The pill wording per failing step. Deliberately never the word "connected" and never a bare
    /// "error": it names the thing that is not happening, because "step 4 failed" sends nobody
    /// anywhere.
    public static func shortFailure(_ step: MCPHealth.Step) -> String {
        switch step {
        case .configured: L("not set up")
        case .launched: L("will not start")
        case .handshake: L("no reply")
        case .toolsListed: L("no tools")
        case .toolCalled: L("comes back empty")
        }
    }

    /// Each failure has exactly one fix, and it is different for every step. This is the whole
    /// reason the five checks are separate: one green dot could only ever say "something is wrong".
    public static func whatToDo(about step: MCPHealth.Step) -> String {
        switch step {
        case .configured:
            L("Press “Connect” next to it. The entry is added to that app's configuration without touching anything already in there.")
        case .launched:
            L("The path saved in that assistant no longer leads to BeLauncher, usually because the app moved folder. Press “Connect” again to write the current one.")
        case .handshake:
            L("The process starts but does not answer. Quit the assistant, open it again and check once more. If it stays like this, reinstall BeLauncher.")
        case .toolsListed:
            L("This version starts but announces no tools. Update BeLauncher from Settings › General.")
        case .toolCalled:
            L("The plumbing works and the content does not arrive. Rebuild the index under “Brain status” and check again; if it is still empty, send the diagnostic.")
        }
    }

    /// The one line above the client list. It answers "can I trust the row below" before anyone
    /// reads the rows.
    public static func summary(of reports: [MCPHealth.Report]) -> Verdict {
        guard !reports.isEmpty else {
            return Verdict(level: .unknown, label: L("unchecked"),
                           headline: L("Nobody has checked this connection yet."),
                           whatToDo: L("Press “%@”: it starts BeLauncher the way your assistant would and asks it a real question.", checkButton))
        }
        let broken = reports.filter { !$0.isConnected }
        guard !broken.isEmpty else {
            let count = reports.count
            return Verdict(level: .working, label: L("everything answers"),
                           headline: count == 1
                               ? L("One assistant is getting real data.")
                               : L("%@ assistants are getting real data.", number(count)),
                           whatToDo: "")
        }
        let names = broken.map(\.clientName).joined(separator: ", ")
        return Verdict(level: .broken, label: L("%@ with no data", String(broken.count)),
                       headline: L("Nothing reaches: %@.", names),
                       whatToDo: L("Open each one to see which step it breaks at."))
    }

    // MARK: - What pressing «Connect» is allowed to claim

    /// Connecting writes a line into another app's configuration file. That is all it does, and
    /// that is all this says.
    ///
    /// The old message was "X can now consult your brain. Restart it so it sees it" — the exact
    /// unverified claim the five-step probe exists to replace. A path in a JSON file does not prove
    /// the assistant launches it: the most common failure in the probe is `launched`, on machines
    /// whose config file said everything was fine.
    public static func connectWrote(client: String) -> String {
        L("Wrote %1$@'s configuration. That is the only thing we can claim so far: restart %1$@ and press “%2$@” to see whether data actually reaches it.",
          client, checkButton)
    }

    public static func connectAlreadyThere(client: String) -> String {
        L("%1$@ already had the BeLauncher entry. A file mentioning it is no proof that anything arrives: press “%2$@” to find out.",
          client, checkButton)
    }

    /// The label on the button that runs the probe. It promises what it does, because the old
    /// button promised connection and delivered a file write.
    public static var checkButton: String { L("Really check it") }
    public static var checkRunning: String { L("Checking…") }
    public static var checkExplanation: String {
        L("It starts BeLauncher exactly as your assistant would, asks it a question whose answer we know, and checks that content comes back. A configuration file mentioning us is not enough.")
    }
}
