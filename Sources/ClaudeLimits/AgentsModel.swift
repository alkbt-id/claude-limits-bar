import AppKit
import Combine

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var sessionTitle: String { self == .claude ? "Claude Code" : "Codex" }
    var resumeCommand: String { self == .claude ? "claude --resume" : "codex resume" }
    func settingsKey(_ key: String) -> String { self == .claude ? key : "codex.\(key)" }
}

/// Each provider owns its history, attention markers and polling state.
@MainActor
final class AgentsModel: ObservableObject {
    let claude: AppModel
    let codex: AppModel
    @Published var selected: AgentKind = .claude
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }
    private var bag = Set<AnyCancellable>()
    private var choseInitialAgent = false

    init(claude: AppModel? = nil, codex: AppModel? = nil) {
        let claude = claude ?? AppModel()
        let codex = codex ?? AppModel(agent: .codex)
        self.claude = claude
        self.codex = codex
        for model in [claude, codex] {
            model.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !self.choseInitialAgent, let first = self.active.first {
                        self.selected = first.agent
                        self.choseInitialAgent = true
                    }
                    self.objectWillChange.send()
                }
            }.store(in: &bag)
        }
    }

    var current: AppModel { selected == .claude ? claude : codex }
    var active: [AppModel] { [claude, codex].filter(\.isRunning) }
    func start() { claude.start(); codex.start() }
    func rescanLogs() { claude.rescanLogs(); codex.rescanLogs() }
    func setPanelHeight(_ height: CGFloat) {
        claude.panelHeight = height
        codex.panelHeight = height
    }
}
