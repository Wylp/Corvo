import AppKit

/// Descobre de qual app veio o conteúdo copiado.
///
/// Duas fontes, nesta ordem: a convenção `org.nspasteboard.source` (tratada no
/// PasteboardMonitor, autoritativa quando presente) e, na falta dela, o app em
/// foco no momento da captura.
///
/// O poll roda a cada 0,3s, então entre o ⌘C e a leitura o usuário pode ter
/// trocado de app. Guardamos a ativação anterior com timestamp: se a troca
/// aconteceu dentro da janela, o crédito vai para o app de antes.
@MainActor
final class SourceTracker {
    private struct Ativacao {
        let source: ItemSource
        let quando: Date
    }

    private let janela: TimeInterval
    private var atual: Ativacao?
    private var anterior: Ativacao?

    /// App que estava em foco antes do painel do Corvo aparecer. É para ele que
    /// o Paster devolve o foco na hora de colar.
    private(set) var appEmFoco: NSRunningApplication?

    init(janela: TimeInterval = 0.3) {
        self.janela = janela
    }

    func registrarAtivacao(_ source: ItemSource, at quando: Date) {
        anterior = atual
        atual = Ativacao(source: source, quando: quando)
    }

    func fonteDaCaptura(at quando: Date) -> ItemSource? {
        guard let atual else { return nil }
        guard quando.timeIntervalSince(atual.quando) < janela,
              let anterior else { return atual.source }
        return anterior.source
    }

    func começarAObservarOSistema() {
        let ws = NSWorkspace.shared
        if let app = ws.frontmostApplication, let source = Self.fonte(de: app) {
            registrarAtivacao(source, at: Date())
        }
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.appEmFoco = app
                }
                guard let source = Self.fonte(de: app) else { return }
                self.registrarAtivacao(source, at: Date())
            }
        }
    }

    private static func fonte(de app: NSRunningApplication) -> ItemSource? {
        guard let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier else { return nil }
        return ItemSource(bundleId: bundleId, name: app.localizedName ?? bundleId)
    }
}
