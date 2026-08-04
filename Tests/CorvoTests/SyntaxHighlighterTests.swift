import Foundation
import Testing
@testable import Corvo

private let curlCommand = #"curl -H "Accept: application/json" https://api.example.com/v1/items"#

private let jsonObject = #"{"id": 7, "name": "raven", "pinned": true, "tags": null}"#

private let swiftFunction = """
func greet(_ name: String) -> String {
    // one line is enough
    return "Hello, \\(name)"
}
"""

/// Ordinary Portuguese that happens to use an English keyword, with a semicolon
/// in the middle of a sentence — both of the things a keen classifier trips on.
private let portugueseProse = """
O contrato prevê que o cliente pode solicitar o return do produto em até trinta \
dias corridos; a devolução é analisada pela equipe antes do reembolso, e o valor \
é creditado na mesma forma de pagamento usada na compra.
"""

@Test func aCurlWithAHeaderAndAUrlIsShell() {
    #expect(SyntaxHighlighter.detect(curlCommand) == .shell)
}

@Test func aJsonObjectIsJson() {
    #expect(SyntaxHighlighter.detect(jsonObject) == .json)
}

@Test func aSwiftFunctionIsCLike() {
    #expect(SyntaxHighlighter.detect(swiftFunction) == .cLike)
}

/// The test that keeps the classifier honest. Colouring prose as code is worse
/// than leaving code uncoloured, so a paragraph carrying a keyword by accident
/// has to come out plain.
@Test func portugueseProseContainingAKeywordIsPlain() {
    #expect(SyntaxHighlighter.detect(portugueseProse) == .plain)
}

@Test func emptyAndBlankTextIsPlain() {
    #expect(SyntaxHighlighter.detect("") == .plain)
    #expect(SyntaxHighlighter.detect("   \n\t  ") == .plain)
}

/// Highlighting may change how a clipping looks and nothing else: not one
/// character of what the user copied may be reordered, dropped or invented.
@Test func highlightingPreservesEveryCharacterOfTheTruncatedInput() {
    let longSnippet = String(repeating: "func step() { return 1 }\n", count: 100)
    #expect(longSnippet.count > SyntaxHighlighter.characterLimit)

    for text in [curlCommand, jsonObject, swiftFunction, portugueseProse, longSnippet, ""] {
        let highlighted = SyntaxHighlighter.highlight(text, as: SyntaxHighlighter.detect(text))
        #expect(String(highlighted.characters)
                == String(text.prefix(SyntaxHighlighter.characterLimit)))
    }
}
