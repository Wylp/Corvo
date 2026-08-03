# Corvo — gerenciador de histórico de área de transferência para macOS

Data: 2026-08-03
Status: aprovado para planejamento

## Objetivo

App macOS nativo que roda em background, captura tudo que passa pela área de
transferência e devolve esse histórico numa janela flutuante acionada por
atalho global. Os itens são organizáveis por **fonte** (o app de onde vieram,
automático) e por **tags** (manual).

Distribuição: open source, instalável via Homebrew cask.

### Não-objetivos da v1

Sync entre máquinas, OCR de imagens, editor de snippets, temas, criptografia
do histórico, plugins, App Store. Nenhum é difícil de encaixar depois; nenhum
é necessário para o app ser útil no primeiro dia.

## Stack

- Swift 6, SwiftUI, target **macOS 14.0+**
- Projeto Xcode comitado no repositório
- **Sem App Sandbox** (Homebrew cask não exige; sandbox complicaria acesso a
  arquivos e Acessibilidade)
- `LSUIElement = true` — app accessory, sem ícone no Dock
- Dependência externa: **GRDB.swift** (SPM). Única do projeto.

## Arquitetura

```
App/
  CorvoApp.swift            @main, MenuBarExtra, ciclo de vida
Clipboard/
  PasteboardMonitor.swift   poller do changeCount + filtro de privacidade
  SourceTracker.swift       heurística do app de origem
  Paster.swift              colar de volta (CGEvent + Acessibilidade)
Storage/
  Database.swift            setup GRDB + migrações versionadas
  Item.swift / Tag.swift    records
  ItemRepository.swift      queries: busca, filtros, retenção
  BlobStore.swift           imagens em disco + coleta de órfãos
UI/
  FloatingPanel.swift       NSPanel hospedando SwiftUI
  HistoryView.swift         carrossel + campo de busca
  ItemCard.swift            card individual
  FilterSidebar.swift       filtros por fonte e por tag
  PreferencesView.swift     preferências
System/
  Hotkey.swift              RegisterEventHotKey (Carbon)
  LoginItem.swift           SMAppService
```

Cada arquivo tem uma responsabilidade e uma interface pequena. `UI/` só
conhece `ItemRepository`; `Clipboard/` não conhece `UI/`.

## Captura

`NSPasteboard` não oferece notificação de mudança. A única abordagem viável é
**poll do `changeCount`** num `Timer` de **0,3s**. É o que todos os
gerenciadores de clipboard do macOS fazem; o custo é desprezível.

A cada mudança detectada, monta-se um `Item`:

| campo | origem |
|---|---|
| `kind` | `text`, `image` ou `file`, derivado dos tipos disponíveis no pasteboard |
| `text` | string para `kind=text`; nome legível para os demais |
| `blob_path` | para `kind=image`: PNG escrito em `blobs/<hash>.png` |
| `file_path` | para `kind=file`: caminho absoluto original (não copiamos o arquivo) |
| `url` | `public.url`, quando presente junto do conteúdo |
| `source_bundle_id` / `source_name` | ver *Atribuição de fonte* |
| `content_hash` | SHA-256 do conteúdo, para deduplicação |

**Arquivos:** guardamos a referência, não uma cópia. Se o arquivo for movido ou
apagado, o card aparece esmaecido e marcado como indisponível. Sem sandbox, não
há necessidade de security-scoped bookmarks.

**Imagens:** não têm caminho de origem (screenshot, por exemplo), então o dado
bruto é escrito em disco. Blobs nunca entram no banco.

## Atribuição de fonte

Duas fontes, nessa ordem de precedência:

1. **`org.nspasteboard.source`** — convenção informal em que o app de origem
   escreve o próprio bundle ID no pasteboard. Quando presente, é autoritativa.
   Poucos apps implementam.
2. **`NSWorkspace.shared.frontmostApplication`** no momento da captura —
   o fallback que responderá pela grande maioria dos casos. Fornece bundle ID,
   nome e ícone.

**Correção da janela de corrida:** entre o `⌘C` e o poll passam até 0,3s. Se o
usuário copia e troca de app imediatamente, o app em foco no momento do poll é o
errado. `SourceTracker` observa `NSWorkspace.didActivateApplicationNotification`
e mantém o app anteriormente ativo com timestamp; se a última troca ocorreu há
menos de 0,3s, o crédito vai para o app anterior.

**Limitação aceita:** conteúdo escrito no pasteboard por script ou processo em
background é atribuído ao app que estava em foco. Marcado com comentário
`ponytail:` no código.

## Privacidade

Trust boundary — sem simplificações aqui.

- Itens marcados com **`org.nspasteboard.ConcealedType`** são descartados sem
  gravar. É a convenção que gerenciadores de senha usam para sinalizar segredos.
- Itens marcados com `org.nspasteboard.TransientType` também são ignorados.
- **Blocklist de apps** configurável nas preferências: nada copiado a partir dos
  bundle IDs listados é gravado.
- O banco fica em `~/Library/Application Support/Corvo/`, permissões padrão do
  usuário. Sem criptografia na v1 (documentado no README).

## Schema

SQLite via GRDB, migrações versionadas explícitas (`DatabaseMigrator`).

```sql
-- v1
CREATE TABLE items (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  kind             TEXT NOT NULL,           -- 'text' | 'image' | 'file'
  text             TEXT,
  blob_path        TEXT,
  file_path        TEXT,
  url              TEXT,
  source_bundle_id TEXT,
  source_name      TEXT,
  content_hash     TEXT NOT NULL,
  pinned           INTEGER NOT NULL DEFAULT 0,
  created_at       DATETIME NOT NULL,
  last_used_at     DATETIME
);
CREATE UNIQUE INDEX idx_items_hash    ON items(content_hash);
CREATE INDEX        idx_items_created ON items(created_at DESC);
CREATE INDEX        idx_items_source  ON items(source_bundle_id);

CREATE TABLE tags (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  name  TEXT NOT NULL,
  color TEXT
);
CREATE UNIQUE INDEX idx_tags_name ON tags(name);

CREATE TABLE item_tags (
  item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  tag_id  INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
  PRIMARY KEY (item_id, tag_id)
);
```

**Deduplicação:** recopiar conteúdo idêntico não cria linha nova —
`INSERT ... ON CONFLICT(content_hash) DO UPDATE SET created_at = excluded.created_at`
promove o item existente para o topo, preservando tags e pin.

**Busca:** `LIKE` sobre `text` **e** `source_name`, de modo que digitar "slack"
filtre por origem sem passar pelo filtro lateral. Com o teto de 1000 itens isso
responde em microssegundos. FTS5 fica marcado com comentário `ponytail:` no
schema e entra apenas se o limite de retenção subir.

**Filtros:** fonte é `WHERE source_bundle_id = ?`; tag é um `JOIN` em
`item_tags`. Os dois combinam com `AND`, e ambos combinam com a busca textual.

**Reatividade:** `ValueObservation` do GRDB alimenta a lista SwiftUI, de forma
que itens capturados pelo poller aparecem sem refresh manual.

## Retenção

Executada na inicialização e a cada hora:

- Limite de **1000 itens** ou **30 dias**, o que ocorrer primeiro.
- Itens **fixados** ou **com ao menos uma tag** nunca expiram e não contam para
  o limite.
- Após a poda, `BlobStore` apaga arquivos em `blobs/` sem linha correspondente.

Ambos os limites são configuráveis nas preferências.

## Janela flutuante

`NSPanel` (nível `.floating`, `hidesOnDeactivate`) hospedando conteúdo SwiftUI.
Uma única janela serve tanto para colar rápido quanto para gerenciar.

**Abertura:** `⌘⇧V` abre centralizada na tela ativa, com o campo de busca já
focado. `Esc` fecha sem colar.

**Layout:** carrossel horizontal de cards no estilo do Paste. Cada card mostra
preview do conteúdo, **ícone do app de origem** no canto, e as tags atribuídas.

**Navegação:** `←`/`→` percorrem os cards, digitar filtra, `Enter` cola o card
selecionado, `Esc` fecha.

**Filtros laterais:** lista de fontes (derivada de `source_bundle_id` distintos,
com ícone) e lista de tags. Clicar filtra; os dois compõem.

**Gerenciamento na mesma janela:** a janela é redimensionável; arrastar um card
sobre uma tag na lateral atribui a tag, `⌘T` abre o campo de tag do card
selecionado, `Delete` apaga o item, `⌘P` fixa/desfixa.

**Atalho global:** `RegisterEventHotKey` do Carbon — é a API que ainda funciona
de forma confiável a partir de um app accessory. Fixo em `⌘⇧V` na v1. Quando
houver pedido de customização, substituir pelo pacote `KeyboardShortcuts`, que
já traz o gravador de atalho.

## Colar de volta

1. Antes de exibir a janela, `SourceTracker` registra o app em foco.
2. No `Enter`: conteúdo do item é escrito no `NSPasteboard`.
3. A janela fecha; o app previamente em foco é reativado.
4. `⌘V` é postado via `CGEvent`.

Exige permissão de **Acessibilidade**. Verificação com `AXIsProcessTrusted()`.
Sem a permissão, o app degrada: apenas copia para o clipboard e exibe aviso
discreto com botão que abre o painel correto das Configurações do Sistema.

`last_used_at` é atualizado no item colado.

## Iniciar com o sistema

`SMAppService.mainApp.register()` / `.unregister()`, exposto como toggle nas
preferências. Aparece corretamente em Ajustes do Sistema → Geral → Itens de
Início de Sessão.

## Distribuição

- Repositório público, licença MIT.
- Bundle ID `com.wylp.corvo`; app instalado como `Corvo.app`.
- Release do GitHub com `.zip` do `.app`, gerado por GitHub Actions.
- Cask Homebrew de token `corvo` — verificado livre em 2026-08-03, assim como o
  nome no GitHub (só projetos pequenos e de domínio não relacionado).
- Assinatura: build ad-hoc na v1. Notarização com Developer ID entra quando a
  conta paga existir — documentar no README que, até lá, a primeira abertura
  exige "Abrir mesmo assim" nas Configurações de Privacidade e Segurança.

## Testes

Um alvo de teste enxuto, cobrindo somente a lógica onde um bug é silencioso:

1. **Deduplicação por hash** — recopiar conteúdo idêntico promove o item
   existente sem duplicar nem perder tags.
2. **Atribuição de fonte** — troca de app dentro da janela de 0,3s credita o app
   anterior; fora dela, credita o atual.
3. **Filtro de privacidade** — item com `ConcealedType` não é gravado; app em
   blocklist não é gravado.
4. **Retenção** — poda respeita o limite, preserva fixados e itens com tag, e
   remove blobs órfãos.

Sem framework extra, sem fixtures, sem suíte por função.

## Decisões deliberadas

| Decisão | Motivo | Quando revisitar |
|---|---|---|
| SQLite/GRDB em vez de SwiftData | tags são muitos-para-muitos; `#Predicate` sobre relação M:N ainda é frágil, e a busca acabaria em SQL manual de qualquer forma | não previsto |
| `LIKE` em vez de FTS5 | 1000 itens tornam a busca instantânea; tabela virtual + triggers é complexidade sem problema correspondente | se o teto de retenção subir muito |
| Uma janela para colar e gerenciar | pedido explícito; evita construir e manter duas telas | se organização em lote ficar penosa |
| Referência a arquivos, não cópia | copiar arquivos multiplicaria uso de disco sem ganho claro | não previsto |
| Sem sandbox | Homebrew não exige; sandbox complicaria Acessibilidade e acesso a arquivos | se a App Store virar alvo |
| Hotkey fixo | zero UI de configuração na v1 | ao primeiro pedido de customização |
