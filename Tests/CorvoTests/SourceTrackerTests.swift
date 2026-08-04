import Foundation
import Testing
@testable import Corvo

private let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
private let terminal = ItemSource(bundleId: "com.apple.Terminal", name: "Terminal")
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test @MainActor func semAtivacaoRegistradaNaoHaFonte() {
    let tracker = SourceTracker()
    #expect(tracker.fonteDaCaptura(at: t0) == nil)
}

@Test @MainActor func trocaRecenteCreditaOAppAnterior() {
    let tracker = SourceTracker(janela: 0.3)
    tracker.registrarAtivacao(slack, at: t0)
    tracker.registrarAtivacao(terminal, at: t0.addingTimeInterval(1))

    // Copiou no Slack e trocou pro Terminal 0,1s antes do poll.
    let fonte = tracker.fonteDaCaptura(at: t0.addingTimeInterval(1.1))

    #expect(fonte == slack)
}

@Test @MainActor func trocaAntigaCreditaOAppAtual() {
    let tracker = SourceTracker(janela: 0.3)
    tracker.registrarAtivacao(slack, at: t0)
    tracker.registrarAtivacao(terminal, at: t0.addingTimeInterval(1))

    let fonte = tracker.fonteDaCaptura(at: t0.addingTimeInterval(5))

    #expect(fonte == terminal)
}

@Test @MainActor func semAppAnteriorATrocaRecenteCreditaOAtual() {
    let tracker = SourceTracker(janela: 0.3)
    tracker.registrarAtivacao(slack, at: t0)

    #expect(tracker.fonteDaCaptura(at: t0.addingTimeInterval(0.1)) == slack)
}
