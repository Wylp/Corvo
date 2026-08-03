import Foundation

/// Guarda dados binários (imagens) em disco, nomeados pelo hash do conteúdo.
/// O banco guarda só o caminho relativo — blob nunca entra em tabela.
final class BlobStore {
    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Idempotente: gravar o mesmo hash de novo não reescreve nem duplica.
    func store(_ data: Data, hash: String, ext: String) throws -> String {
        let relativo = "\(hash).\(ext)"
        let destino = directory.appendingPathComponent(relativo)
        guard !fm.fileExists(atPath: destino.path) else { return relativo }
        try data.write(to: destino, options: .atomic)
        return relativo
    }

    func url(for relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// Remove todo arquivo do diretório que não esteja em `live`.
    @discardableResult
    func collectGarbage(keeping live: Set<String>) throws -> Int {
        let existentes = try fm.contentsOfDirectory(atPath: directory.path)
        var removidos = 0
        for nome in existentes where !live.contains(nome) {
            try fm.removeItem(at: directory.appendingPathComponent(nome))
            removidos += 1
        }
        return removidos
    }
}
