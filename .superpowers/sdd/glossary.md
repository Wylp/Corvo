# Glossário de tradução — português → inglês

Fonte da verdade para renomear o código já escrito (tasks 1–7) e para escrever o
que ainda falta. Tudo aqui bate exatamente com
`docs/superpowers/plans/2026-08-03-corvo.md`.

**Não mudam** (já estão em inglês): `ClipItem`, `ClipKind`, `Tag`, `ItemTag`,
`AppDatabase`, `BlobStore`, `ItemRepository`, `Retention`, `RetentionPolicy`,
`CapturedItem`, `ItemSource`, `SourceSummary`, `SourceTracker`,
`PasteboardReading`, `PasteboardMonitor`, `Paster`, `Preferences`,
`GlobalHotkey`, `LoginItem`, `FloatingPanel`, `PanelController`,
`AppEnvironment`, `HistoryModel`, `HistoryView`, `ItemCard`, `FilterSidebar`,
`PreferencesView`, `AppIcon`, `CorvoApp`, `AppDelegate`, `BundleAnchor`, e todas
as tabelas e colunas do SQLite (`item`, `tag`, `itemTag`, `contentHash`,
`sourceBundleId`, `blobPath`, `filePath`, `createdAt`, `lastUsedAt`, `pinned`,
`kind`, `url`, `sourceName`, `color`, `name`, `id`, `itemId`, `tagId`).

## Decisões não óbvias

| português | inglês | razão |
|---|---|---|
| `tipos` (PasteboardReading) | `availableTypes` | `NSPasteboard.types` já existe e é opcional; declarar `types` na extensão dá `invalid redeclaration` e quebra o build. |
| `podar()` (AppEnvironment) | `runPrune()` | `prune` já é o método de `Retention` que este chama; dois `prune` a uma linha de distância leem como recursão. |
| `padrao` (RetentionPolicy) | `standard` | `default` é palavra reservada em Swift e exigiria crase em todo uso. `standard` segue `UserDefaults.standard`. |
| `janela` (SourceTracker) | `switchWindow` | `window` num arquivo cheio de `NSWorkspace`/`NSRunningApplication` lê como janela de UI; `switchWindow` diz que é a janela de tempo da troca de foco. |
| `erro` (PreferencesView) | `errorMessage` | dentro do `catch`, o `error` implícito do Swift sombrearia a propriedade e `error = error.localizedDescription` não compilaria. |
| `texto(_:)` (helper de teste) | `textItem(_:)` | `text` colidiria visualmente com `ClipKind.text` e `ClipItem.text` na mesma linha (`textItem("a")` vs `kind: .text`). |
| `datas` / `strings` (PasteboardFalso) | `dataByType` / `stringsByType` | `data` colide com o método `data(forType:)` do próprio protocolo; os dois viraram par simétrico. |
| `despachar` (GlobalHotkey) | `handleHotkeyEvent` | `dispatch` no escopo global de um arquivo que importa Foundation/Dispatch é um nome que pede confusão. |
| `ambiente()` (helpers de teste) | `makeEnvironment()` | `environment()` colidiria com o conceito SwiftUI e com `AppEnvironment`; o prefixo `make` marca fábrica de teste. |
| `maxAgeDias` | `maxAgeDays` | **muda a chave do `UserDefaults`** (`"maxAgeDias"` → `"maxAgeDays"`). Aceitável: o app não foi lançado. Quem já tiver o default antigo volta para o padrão de 30 dias. |
| `"Imagem"` (PasteboardMonitor) | `"Image"` | é conteúdo gravado no banco, não string de UI: não entra no String Catalog. |

## Sources/Corvo/App/CorvoApp.swift

| português | inglês |
|---|---|
| `"Sair"` | `"Quit"` |
| `"Mostrar histórico"` | `"Show History"` |
| `"Preferências…"` | `"Settings…"` |
| `painel` | `panel` |
| `atalho` | `hotkey` |
| `colar(_:)` | `paste(_:)` |
| `avisarFaltaDePermissao()` | `warnMissingPermission()` |
| `alerta` | `alert` |
| `colou` | `pasted` |
| `Text("histórico entra aqui")` | `Text("history goes here")` |
| `"Corvo: não foi possível registrar ⌘⇧V — atalho já em uso?"` | `"Corvo: could not register ⌘⇧V — shortcut already taken?"` |
| `"Corvo: colar item \(id)"` | `"Corvo: paste item \(id)"` |
| `"Copiado, mas não colado"` | `"Copied, but not pasted"` |
| `"Abrir Ajustes"` | `"Open Settings"` |
| `"Agora não"` | `"Not now"` |

## Sources/Corvo/App/AppEnvironment.swift

| português | inglês |
|---|---|
| `iniciar()` | `start()` |
| `podar()` | `runPrune()` — ver decisões |
| `podaTimer` | `pruneTimer` |

## Sources/Corvo/Storage/ClipItem.swift

Só comentários:

| português | inglês |
|---|---|
| `Conteúdo para .text; nome legível para .image e .file.` | `Content for .text; human-readable name for .image and .file.` |
| `Caminho relativo dentro do diretório de blobs, só para .image.` | `Path relative to the blob directory, .image only.` |
| `Caminho absoluto original, só para .file. Não copiamos o arquivo.` | `Original absolute path, .file only. We never copy the file.` |
| `public.url quando veio junto do conteúdo.` | `public.url when it came along with the content.` |

## Sources/Corvo/Storage/AppDatabase.swift

Só comentários:

| português | inglês |
|---|---|
| `Diretório de suporte do app: …` | `App support directory: …` |
| `Abre o banco. url == nil abre em memória — é o que os testes usam.` | `Opens the database. url == nil opens in memory — that is what tests use.` |
| `ponytail: busca é LIKE sobre text e sourceName. …` | `ponytail: search is a LIKE over text and sourceName. …` |

## Sources/Corvo/Storage/BlobStore.swift

| português | inglês |
|---|---|
| `relativo` | `relativePath` |
| `destino` | `destination` |
| `existentes` | `existing` |
| `removidos` | `removed` |
| `nome` | `name` |
| `Guarda dados binários (imagens) em disco…` | `Keeps binary data (images) on disk…` |
| `Idempotente: gravar o mesmo hash de novo…` | `Idempotent: storing the same hash again…` |
| `Remove todo arquivo do diretório que não esteja em live.` | `Removes every file in the directory that is not in live.` |

## Sources/Corvo/Storage/ItemRepository.swift

| português | inglês |
|---|---|
| `existente` | `existing` |
| `condicoes` | `conditions` |
| `busca` (local de `search`) | `query` |
| `limpo` | `trimmed` |
| `nova` (Tag) | `newTag` |
| `Conteúdo lido do pasteboard, antes de virar linha no banco.` | `Content read from the pasteboard, before it becomes a database row.` |
| `Insere. Se o contentHash já existir, promove…` | `Inserts. If contentHash already exists, promotes…` |
| `text casa conteúdo ou nome da fonte…` | `text matches content or source name…` |
| `ponytail: LIKE com scan. Ver comentário do índice em AppDatabase.` | `ponytail: LIKE with a scan. See the index comment in AppDatabase.` |

## Sources/Corvo/Storage/Retention.swift

| português | inglês |
|---|---|
| `padrao` | `standard` — ver decisões |
| `protegidos` | `protected` |
| `removidos` | `removed` |
| `corte` | `cutoff` |
| `Poda o histórico. Item fixado ou com ao menos uma tag é protegido…` | `Prunes the history. An item that is pinned or has at least one tag is protected…` |

## Sources/Corvo/Clipboard/PasteboardReading.swift

| português | inglês |
|---|---|
| `tipos` | `availableTypes` — ver decisões |
| `Só o que o monitor precisa do pasteboard…` | `Only what the monitor needs from the pasteboard…` |
| `A propriedade se chama tipos, não types: NSPasteboard.types já existe (e é opcional), então redeclarar na extensão daria invalid redeclaration.` | `The property is called availableTypes, not types: NSPasteboard.types already exists (and is optional), so redeclaring it in the extension would be an invalid redeclaration.` |
| `flatMap, não first: a guarda de sigilo precisa enxergar o marcador em qualquer item…` | `flatMap, not first: the secrecy guard has to see the marker on any item…` |

## Sources/Corvo/Clipboard/SourceTracker.swift

| português | inglês |
|---|---|
| `Ativacao` | `Activation` |
| `quando` | `when` |
| `janela` | `switchWindow` — ver decisões |
| `atual` | `current` |
| `anterior` | `previous` |
| `appEmFoco` | `focusedApp` |
| `registrarAtivacao(_:at:)` | `recordActivation(_:at:)` |
| `fonteDaCaptura(at:)` | `captureSource(at:)` |
| `começarAObservarOSistema()` | `startObservingSystem()` |
| `fonte(de:)` (static privada) | `source(of:)` |
| `Descobre de qual app veio o conteúdo copiado.` | `Figures out which app the copied content came from.` |
| `App que estava em foco antes do painel do Corvo aparecer…` | `The app that was focused before Corvo's panel appeared…` |

## Sources/Corvo/Clipboard/PasteboardMonitor.swift

| português | inglês |
|---|---|
| `ultimoChangeCount` | `lastChangeCount` |
| `atual` | `current` |
| `tipos` (local) | `types` |
| `declarada` | `declared` |
| `inferida` | `inferred` |
| `fonte` | `source` |
| `capturar(tipos:)` | `capture(types:)` |
| `capturado` | `captured` |
| `arquivos` / `arquivo` | `files` / `file` |
| `tipo` | `type` |
| `bruto` | `raw` |
| `paraPNG(_ dados:)` | `toPNG(_ data:)` |
| `texto` | `text` |
| `"Imagem"` | `"Image"` — ver decisões |
| `ponytail: NSPasteboard não notifica mudanças…` | `ponytail: NSPasteboard does not notify on change…` |
| `Trust boundary: gerenciadores de senha marcam o conteúdo…` | `Trust boundary: password managers mark their content…` |
| `A blocklist confere as DUAS identidades…` | `The blocklist checks BOTH identities…` |
| `ponytail: só o primeiro arquivo de uma cópia múltipla é capturado…` | `ponytail: only the first file of a multi-file copy is captured…` |

## Sources/Corvo/Clipboard/Paster.swift

| português | inglês |
|---|---|
| `temPermissao` | `hasPermission` |
| `pedirPermissao()` | `requestPermission()` |
| `abrirAjustesDeAcessibilidade()` | `openAccessibilitySettings()` |
| `escreverNoClipboard(_:blobs:)` | `writeToClipboard(_:blobs:)` |
| `escreverNoClipboard(_:blobs:em:)` | `writeToClipboard(_:blobs:to:)` |
| `colar(_:blobs:em app:)` | `paste(_:blobs:into app:)` |
| `postarCmdV()` | `postCmdV()` |
| `chave` | `key` |
| `caminho` | `path` |
| `fonte` (CGEventSource) | `source` |
| `baixo` / `cima` | `down` / `up` |

## Sources/Corvo/System/Preferences.swift

| português | inglês |
|---|---|
| `maxAgeDias` | `maxAgeDays` — ver decisões (muda a chave do UserDefaults) |
| `"maxAgeDias"` (chave) | `"maxAgeDays"` |
| `UserDefaults tipado. Um lugar só para tudo que o usuário configura.` | `Typed UserDefaults. One place for everything the user configures.` |

## Sources/Corvo/System/GlobalHotkey.swift

| português | inglês |
|---|---|
| `handlersDeAtalho` | `hotkeyHandlers` |
| `proximoId` | `nextHotkeyId` |
| `despachar` | `handleHotkeyEvent` — ver decisões |
| `tipo` (EventTypeSpec) | `eventType` |
| `Registra um atalho global. Enquanto a instância viver, o atalho existe.` | `Registers a global shortcut. The shortcut lives as long as the instance does.` |
| `ponytail: dicionário global porque o callback do Carbon…` | `ponytail: a global dictionary because the Carbon callback…` |

## Sources/Corvo/System/LoginItem.swift

| português | inglês |
|---|---|
| `ativo` | `isEnabled` |
| `definir(_ ativo:)` | `setEnabled(_ enabled:)` |
| `Registro no "Itens de Início de Sessão" dos Ajustes do Sistema.` | `Registration in System Settings → "Login Items".` |

## Sources/Corvo/UI/FloatingPanel.swift

| português | inglês |
|---|---|
| `estaVisivel` | `isVisible` |
| `alternar()` | `toggle()` |
| `mostrar()` | `show()` |
| `esconder()` | `hide()` |
| `// Esc fecha` | `// Esc closes` |

## Sources/Corvo/UI/AppIcon.swift

| português | inglês |
|---|---|
| `imagem(paraBundleId:)` | `image(forBundleId:)` |
| `cacheado` | `cached` |
| `icone` | `icon` |

## Sources/Corvo/UI/HistoryModel.swift

| português | inglês |
|---|---|
| `busca` | `query` |
| `fonteSelecionada` | `selectedSource` |
| `tagSelecionada` | `selectedTag` |
| `itens` | `items` |
| `fontes` | `sources` |
| `indiceSelecionado` | `selectedIndex` |
| `itemSelecionado` | `selectedItem` |
| `cancelavel` | `observationCancellable` |
| `recarregar()` | `reload()` |
| `observarBanco()` | `observeDatabase()` |
| `mover(_ passo:)` | `move(_ step:)` |
| `tags(de item:)` | `tags(for item:)` |
| `adicionarTag(_ nome:a:)` | `addTag(_ name:to:)` |
| `alternarFixado(_:)` | `togglePinned(_:)` |
| `apagar(_:)` | `delete(_:)` |
| `marcarUso(_:)` | `markUsed(_:)` |
| `Faz a lista reagir ao poller sem refresh manual.` | `Makes the list react to the poller with no manual refresh.` |

## Sources/Corvo/UI/ItemCard.swift

| português | inglês |
|---|---|
| `selecionado` | `isSelected` |
| `arquivoSumiu` | `fileIsMissing` |
| `caminho` | `path` |
| `icone` | `icon` |
| `"Desconhecido"` | `"Unknown"` (via `String(localized:)`) |
| `"Imagem indisponível"` | `"Image unavailable"` |
| `"indisponível"` | `"unavailable"` |

## Sources/Corvo/UI/FilterSidebar.swift

| português | inglês |
|---|---|
| `fonte` | `source` |
| `"Fontes"` | `"Sources"` |
| `"Tags"` | `"Tags"` |

## Sources/Corvo/UI/HistoryView.swift

| português | inglês |
|---|---|
| `aoColar` | `onPaste` |
| `editandoTag` | `isEditingTag` |
| `textoDaTag` | `tagText` |
| `buscaFocada` | `isSearchFocused` |
| `busca` (subview) | `searchField` |
| `carrossel` | `carousel` |
| `atalhos` | `shortcuts` |
| `folhaDeTag` | `tagSheet` |
| `confirmarTag()` | `confirmTag()` |
| `colarSelecionado()` | `pasteSelected()` |
| `novo` (onChange) | `newIndex` |
| `"Buscar por conteúdo ou app…"` | `"Search content or app…"` |
| `"Nada por aqui"` | `"Nothing here yet"` |
| `"Copie algo e volte."` | `"Copy something and come back."` |
| `"Nova tag"` | `"New tag"` |
| `"nome da tag"` | `"Tag name"` |
| `"Cancelar"` | `"Cancel"` |
| `"Adicionar"` | `"Add"` |

## Sources/Corvo/UI/PreferencesView.swift

| português | inglês |
|---|---|
| `iniciarComSistema` | `launchAtLogin` |
| `maxAgeDias` | `maxAgeDays` |
| `erro` | `errorMessage` — ver decisões |
| `novo` (onChange) | `enabled` / `value` |
| `"Iniciar com o sistema"` | `"Launch at login"` |
| `"Retenção"` | `"Retention"` |
| `"Máximo de itens"` | `"Maximum items"` |
| `"Apagar após (dias)"` | `"Delete after (days)"` |
| `"Itens fixados ou com tag nunca expiram."` | `"Pinned or tagged items never expire."` |
| `"Apps ignorados"` | `"Ignored apps"` |
| `"Um bundle ID por linha. Nada copiado nesses apps é guardado."` | `"One bundle ID per line. Nothing copied in these apps is kept."` |
| `"Permissões"` | `"Permissions"` |
| `"Acessibilidade concedida"` | `"Accessibility granted"` |
| `"Acessibilidade pendente"` | `"Accessibility pending"` |
| `"Abrir Ajustes"` | `"Open Settings"` |
| `"Sem ela, o Corvo copia mas não cola sozinho."` | `"Without it, Corvo copies but does not paste for you."` |
| `"Não foi possível alterar"` | `"Could not apply the change"` |

## Nomes de função de teste

### Tests/CorvoTests/SmokeTests.swift (apagado na Task 2 — nada a renomear)

| português | inglês |
|---|---|
| `alvoDeTesteEstaLigado` | `testTargetIsWiredUp` |

### Tests/CorvoTests/AppDatabaseTests.swift

| português | inglês |
|---|---|
| `migracaoCriaAsTresTabelas` | `migrationCreatesTheThreeTables` |
| `chaveEstrangeiraApagaAssociacaoJuntoComOItem` | `foreignKeyDeletesTheAssociationAlongWithTheItem` |
| `tabelas` | `tables` |
| `restantes` | `remaining` |

### Tests/CorvoTests/BlobStoreTests.swift

| português | inglês |
|---|---|
| `gravaEDevolveCaminhoRelativo` | `storesAndReturnsARelativePath` |
| `gravarOMesmoHashDuasVezesNaoDuplica` | `storingTheSameHashTwiceDoesNotDuplicate` |
| `coletaRemoveOrfaosEPreservaVivos` | `garbageCollectionRemovesOrphansAndKeepsLiveFiles` |
| `caminho` | `path` |
| `arquivos` | `files` |
| `vivo` | `live` |
| `removidos` | `removed` |

### Tests/CorvoTests/ItemRepositoryTests.swift

| português | inglês |
|---|---|
| `insereEBusca` | `insertsAndSearches` |
| `conteudoRepetidoSobeAoTopoSemDuplicarNemPerderTagOuPin` | `repeatedContentMovesToTheTopWithoutDuplicatingOrLosingTagOrPin` |
| `buscaTextualTambemCasaONomeDaFonte` | `textSearchAlsoMatchesTheSourceName` |
| `filtrosDeFonteETagCombinamComAnd` | `sourceAndTagFiltersCombineWithAnd` |
| `imagemVaiParaDiscoENaoParaOBanco` | `imageGoesToDiskNotToTheDatabase` |
| `resumoDeFontesContaItensPorApp` | `sourceSummaryCountsItemsPerApp` |
| `buscaCombinaOsTresFiltrosSimultaneamente` | `searchCombinesAllThreeFiltersAtOnce` |
| `texto(_:)` | `textItem(_:)` |
| `achados` | `found` |
| `idDeNovo` | `idAgain` |
| `todos` | `all` |
| `soFonte` | `sourceOnly` |
| `fonteETag` | `sourceAndTag` |
| `capturada` | `captured` |
| `fontes` | `sources` |
| `um`, `tres`, `quatro`, `cinco`, `seis` | `one`, `three`, `four`, `five`, `six` |

### Tests/CorvoTests/RetentionTests.swift

| português | inglês |
|---|---|
| `podaPorIdadeRemoveOsAntigos` | `ageBasedPruneRemovesOldItems` |
| `fixadosEItensComTagNuncaExpiram` | `pinnedAndTaggedItemsNeverExpire` |
| `podaPorQuantidadeNaoContaProtegidos` | `countBasedPruneDoesNotCountProtectedItems` |
| `podaApagaBlobsQueFicaramOrfaos` | `pruneDeletesBlobsThatBecameOrphans` |
| `tagProtegeTambemNaPodaPorQuantidade` | `tagAlsoProtectsOnTheCountBasedPrune` |
| `podaPorQuantidadeApagaOsMaisAntigosNaoOsMaisNovos` | `countBasedPruneDeletesTheOldestNotTheNewest` |
| `idadeEQuantidadePodamJuntasSemContarDuasVezes` | `ageAndCountPruneTogetherWithoutDoubleCounting` |
| `agora` | `now` |
| `ambiente()` | `makeEnvironment()` |
| `texto(_:)` | `textItem(_:)` |
| `conteudos(_:)` | `contents(_:)` |
| `retencao` | `retention` |
| `politica` | `policy` |
| `removidos` | `removed` |
| `restantes` | `remaining` |
| `antigo` (Date) | `oldDate` |
| `fixado` | `pinned` |
| `comTag` | `tagged` |
| `protegido` | `protected` |
| `hoje` | `today` |
| `antes` / `depois` | `before` / `after` |

### Tests/CorvoTests/SourceTrackerTests.swift

| português | inglês |
|---|---|
| `semAtivacaoRegistradaNaoHaFonte` | `withNoRecordedActivationThereIsNoSource` |
| `trocaRecenteCreditaOAppAnterior` | `aRecentSwitchCreditsThePreviousApp` |
| `trocaAntigaCreditaOAppAtual` | `anOldSwitchCreditsTheCurrentApp` |
| `semAppAnteriorATrocaRecenteCreditaOAtual` | `withNoPreviousAppARecentSwitchCreditsTheCurrentOne` |
| `fonte` | `source` |

### Tests/CorvoTests/PasteboardMonitorTests.swift

| português | inglês |
|---|---|
| `PasteboardFalso` | `FakePasteboard` |
| `copiarTexto(_:)` | `copyText(_:)` |
| `tipos` | `availableTypes` |
| `strings` | `stringsByType` |
| `datas` | `dataByType` |
| `ambiente()` | `makeEnvironment()` |
| `capturaTextoQuandoOChangeCountMuda` | `capturesTextWhenTheChangeCountChanges` |
| `naoRecapturaSeOChangeCountNaoMudou` | `doesNotRecaptureWhenTheChangeCountIsUnchanged` |
| `descartaConteudoMarcadoComoSigiloso` | `discardsContentMarkedAsConcealed` |
| `descartaConteudoTransitorio` | `discardsTransientContent` |
| `descartaConteudoDeAppNaBlocklist` | `discardsContentFromABlocklistedApp` |
| `descartaTextoVazio` | `discardsEmptyText` |
| `descartaQuandoAFonteInferidaEstaNaBlocklist` | `discardsWhenTheInferredSourceIsBlocklisted` |
| `gravaQuandoAFonteInferidaNaoEstaNaBlocklist` | `storesWhenTheInferredSourceIsNotBlocklisted` |
| `fonteDeclaradaNaoEncobreFonteInferidaNaBlocklist` | `aDeclaredSourceDoesNotMaskTheInferredOneInTheBlocklist` |
| `itens` | `items` |

### Tests/CorvoTests/HistoryModelTests.swift (Task 9, ainda não escrito)

| português | inglês |
|---|---|
| `modelo()` | `makeModel()` |
| `recarregarTrazOsItensMaisNovosPrimeiro` | `reloadBringsTheNewestItemsFirst` |
| `buscaFiltraERessetaASelecao` | `theQueryFiltersAndResetsTheSelection` |
| `moverNaoSaiDosLimites` | `moveStaysWithinBounds` |
| `listaDeFontesAcompanhaOsItens` | `theSourceListFollowsTheItems` |

### Tests/CorvoTests/IntegracaoTests.swift → IntegrationTests.swift (Task 14)

| português | inglês |
|---|---|
| `IntegracaoTests.swift` | `IntegrationTests.swift` |
| `pasteboardPrivado()` | `privatePasteboard()` |
| `ambiente(_:)` | `makeEnvironment(_:)` |
| `capturaTextoDeUmNSPasteboardReal` | `capturesTextFromARealNSPasteboard` |
| `capturaImagemDeUmNSPasteboardRealEGravaPNGLegivel` | `capturesImageFromARealNSPasteboardAndWritesAReadablePNG` |
| `capturaArquivoDeUmNSPasteboardRealGuardandoOCaminho` | `capturesFileFromARealNSPasteboardKeepingThePath` |
| `pasteboardRealMarcadoComoSigilosoNaoEGravado` | `aRealPasteboardMarkedConcealedIsNotStored` |
| `voltaAoPasteboardOMesmoConteudoQueFoiCapturado` | `writesBackToThePasteboardTheSameContentThatWasCaptured` |
| `fluxoCompletoDoPollerAteAListaDaTela` | `fullFlowFromThePollerToTheOnScreenList` |
| `bancoEmDiscoPersisteEAMigracaoEIdempotente` | `theOnDiskDatabasePersistsAndTheMigrationIsIdempotent` |
| `imagem` | `image` |
| `regravada` | `reloaded` |
| `arquivo` | `file` |
| `origem` / `destino` | `source` / `destination` |
| `caminho` | `path` |

### Tests/CorvoTests/LocalizationTests.swift (Task 10, novo)

Nasce em inglês: `theAppIsEnglishFirstWithBrazilianPortugueseRegistered`,
`appBundle`.

## Strings de fixture dos testes

Não são visíveis ao usuário, mas viram inglês junto com o resto do código para o
arquivo não ficar bilíngue. Quem renomear precisa trocar as duas pontas (o valor
inserido e o valor esperado no `#expect`) — vários testes usam a string também
como `contentHash`.

| português | inglês |
|---|---|
| `"trabalho"` | `"work"` |
| `"pessoal"` | `"personal"` |
| `"importante"` | `"important"` |
| `"guardar"` | `"keep"` |
| `"olá"` | `"hello"` |
| `"olá mundo"` | `"hello world"` |
| `"mundo"` (busca) | `"world"` |
| `"outra coisa"` | `"something else"` |
| `"repetido"` | `"repeated"` |
| `"alpha um/dois/tres/quatro/cinco/seis"` | `"alpha one/two/three/four/five/six"` |
| `"beta quatro"` | `"beta four"` |
| `"velho"` / `"novo"` | `"old"` / `"new"` |
| `"velho0"`, `"novo0"` | `"old0"`, `"new0"` |
| `"velhoComTag"` | `"oldTagged"` |
| `"fixado"` | `"pinned"` |
| `"com tag"` | `"tagged"` |
| `"descartável"` | `"disposable"` |
| `"comtag\(i)"` | `"tagged\(i)"` |
| `"sotag\(i)"` | `"untagged\(i)"` |
| `"velha"` (hash de blob) | `"old"` |
| `"orfao"` | `"orphan"` |
| `"vivo"` | `"live"` |
| `"senha-secreta"` | `"secret-password"` |
| `"senha"` | `"password"` |
| `"segredo"` | `"secret"` |
| `"temporário"` | `"temporary"` |
| `"texto normal"` | `"normal text"` |
| `"texto de verdade"` | `"real text"` |
| `"ida e volta"` | `"round trip"` |
| `"primeiro"` / `"segundo"` | `"first"` / `"second"` |
| `"prim"` (busca) | `"fir"` |
| `"sobrevivi"` | `"survived"` |
| `"nota.txt"` / `"oi"` | `"note.txt"` / `"hi"` |
| `"antigo"` / `"recente"` | `"old"` / `"recent"` |
| `"alfa"` | `"alpha"` |
| `"corvo-disco-…"` (tempdir) | `"corvo-disk-…"` |
| `"Imagem"` (CapturedItem de teste) | `"Image"` |

## Divergências plano × código encontradas

Registradas, não adivinhadas. As duas primeiras foram **sincronizadas no plano**
(o plano trazia código que o commit de correção já tinha invalidado); as demais
ficam só anotadas.

1. **`NSPasteboard.tipos` — `first?.types` vs `flatMap(\.types)`.** O plano tinha
   `pasteboardItems?.first?.types`; o código traz `flatMap(\.types)` desde
   `8815731` (guarda de sigilo cega para marcador fora do primeiro item). O plano
   agora reflete o código.
2. **`PasteboardMonitor.poll` — checagem da blocklist.** O plano tinha
   `let fonte = declarada ?? tracker.fonteDaCaptura(...)` e uma única checagem; o
   código checa `declared` **e** `inferred` (bypass de blocklist via fonte
   declarada, mesmo commit). O plano agora reflete o código, junto com o
   `ponytail:` de cópia múltipla de arquivos que só existia no código.
3. **`ambiente()` de `PasteboardMonitorTests` devolve 6 elementos**, não 4: o
   código expõe também `tracker` e `prefs`. Sincronizado no plano.
4. **Três testes de blocklist só existem no código** (`descartaQuandoAFonteInferida…`,
   `gravaQuandoAFonteInferida…`, `fonteDeclaradaNaoEncobre…`). Sincronizados no
   plano, porque são o que cobre a correção do item 2.
5. **`buscaCombinaOsTresFiltrosSimultaneamente`** (ItemRepositoryTests) e os três
   testes extras de `RetentionTests` (`tagProtegeTambemNaPodaPorQuantidade`,
   `podaPorQuantidadeApagaOsMaisAntigos…`, `idadeEQuantidadePodamJuntas…`) foram
   adicionados nas revisões e não estavam no plano. Sincronizados.
6. **`SmokeTests.swift` não existe mais**: criado na Task 1 (`31e45d4`) e apagado
   no commit da Task 2 (`b4d8b98`). `alvoDeTesteEstaLigado` está no glossário por
   completude, mas **não há arquivo para renomear**. O plano passou a declarar a
   remoção nos Files da Task 2.
7. **`Preferences.maxAgeDias` tem default diferente**: o plano dizia `30`
   literal, o código deriva `Int(RetentionPolicy.padrao.maxAge / 86400)`. O
   código venceu.
8. **`project.yml` do plano não tinha o bloco `info.properties`** que o arquivo
   real tem (com `CFBundleDevelopmentRegion`, `LSUIElement` etc.). Sincronizado —
   e é esse bloco que a Task 10 edita.
9. **Contagens de teste do plano estavam erradas** (dizia 26 ao fim da Task 7; o
   repositório tem 32). Recontadas ao longo do documento: 1 → 2 → 5 → 12 → 19 →
   23 → 32 → 36 → 37 → 44.
10. **`SourceTrackerTests` no plano não tinha `@MainActor`** nas funções de teste;
    o código tem (`@Test @MainActor`). O plano agora reflete o código.
