import Foundation

/// Turns a flow into the exact list of actions to perform, in order.
///
/// Pure on purpose: what a flow does is decided here and can be asserted in a test, while the
/// app layer only knows how to carry each action out.
public enum FlowRunner {

    public static func plan(
        _ flow: Flow,
        snippets: [Snippet] = [],
        expander: SnippetExpander = SnippetExpander()
    ) -> [LauncherModel.Action] {
        var actions: [LauncherModel.Action] = []

        for step in flow.steps {
            switch step {
            case .openApp(let path):
                actions.append(.launchApplication(path: path))

            case .openURL(let url):
                if let built = WorkflowURL.build(template: url, query: "") {
                    actions.append(.openURL(built))
                }

            case .openFile(let path):
                actions.append(.openFile(path: path))

            case .copyText(let text):
                actions.append(.copyToClipboard(text: text, cursorOffset: nil))

            case .runSnippet(let keyword):
                guard let snippet = snippets.first(where: { $0.keyword == keyword.lowercased() }) else { continue }
                let expanded = expander.expand(snippet.body)
                actions.append(.copyToClipboard(text: expanded.text, cursorOffset: expanded.cursorOffset))

            case .runShortcut(let name):
                actions.append(.runShortcut(name: name))

            case .timer(let minutes, let label):
                actions.append(.startTimer(minutes: minutes, label: label))

            case .wait(let seconds):
                actions.append(.wait(seconds: seconds))
            }
        }

        actions.append(.dismiss)
        return actions
    }
}
