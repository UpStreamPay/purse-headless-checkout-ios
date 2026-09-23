import Testing
import UIKit
@testable import PurseHeadlessCheckout

/// `PurseTheme.resolve()`'s fallback chain — web's `Theme.build()`: scope variant → scope → global
/// variant → global.
struct PurseThemeTests {

    @Test func anEmptyThemeResolvesToTheDefault() {
        let resolved = PurseTheme().resolve()
        #expect(resolved.label.color == PurseTheme.default.global?.color)
        #expect(resolved.gap == 8)
    }

    /// Setting only `global` recolours labels, helper texts and inputs at once.
    @Test func globalCascadesToEveryScopeWithNoOverrideOfItsOwn() {
        let color = UIColor.systemPurple
        let theme = PurseTheme(global: .init(color: color))
        let resolved = theme.resolve()
        #expect(resolved.label.color == color)
        #expect(resolved.helperText.color == color)
        #expect(resolved.input.color == color)
    }

    /// A scope's own value beats the global fallback.
    @Test func aScopeValueWinsOverGlobal() {
        let theme = PurseTheme(global: .init(color: .black), label: .init(color: .systemBlue))
        #expect(theme.resolve().label.color == .systemBlue)
        #expect(theme.resolve().helperText.color == .black)
    }

    /// Only the error message's colour changes — nothing else.
    @Test func helperTextInvalidChangesOnlyTheErrorMessageColour() {
        let theme = PurseTheme(helperTextInvalid: .init(color: .systemRed))
        let resolved = theme.resolve()
        #expect(resolved.helperTextInvalid.color == .systemRed)
        #expect(resolved.helperText.color == PurseTheme.default.global?.color)
        #expect(resolved.label.color == PurseTheme.default.global?.color)
    }

    /// Fallback order for an invalid-state scope: scope variant → scope → global invalid → global.
    @Test func labelInvalidFallsBackThroughGlobalInvalidBeforeGlobal() {
        let globalInvalid = UIColor.systemOrange
        let theme = PurseTheme(global: .init(color: .black), globalInvalid: .init(color: globalInvalid))
        // No `label` and no `labelInvalid` set — falls all the way to `globalInvalid`.
        #expect(theme.resolve().labelInvalid.color == globalInvalid)

        // `label` set, `labelInvalid` not: the scope beats the global variant.
        let withLabel = PurseTheme(global: .init(color: .black), globalInvalid: .init(color: globalInvalid), label: .init(color: .systemBlue))
        #expect(withLabel.resolve().labelInvalid.color == .systemBlue)
    }

    /// The most specific value always wins: a variant beats its own scope.
    @Test func aVariantWinsOverItsOwnScope() {
        let theme = PurseTheme(label: .init(color: .black), labelInvalid: .init(color: .systemRed))
        #expect(theme.resolve().labelInvalid.color == .systemRed)
    }

    @Test func inputStyleCarriesPlaceholderAndBackgroundIndependently() {
        let theme = PurseTheme(input: .init(placeholderColor: .lightGray, backgroundColor: .white))
        let resolved = theme.resolve()
        #expect(resolved.input.placeholderColor == .lightGray)
        #expect(resolved.input.backgroundColor == .white)
    }

    @Test func gapFallsBackToTheDefaultWhenUnset() {
        #expect(PurseTheme().resolve().gap == 8)
        #expect(PurseTheme(gap: 16).resolve().gap == 16)
    }
}

/// Card form copy and the error display rule — Android's `rememberCardTexts` and
/// `FieldUiState.message()`.
struct CardFormCopyTests {

    private let texts = CardFormTexts().resolved(locale: "en")[.expDate]!

    @Test func errorsShowOnlyOnceTheShopperLeavesTheField() {
        // Typing an incomplete value: nothing, however invalid.
        #expect(texts.error(for: .init(isValid: false, isFocused: true, hasContent: true)) == nil)
        // Leaving it invalid: format error.
        #expect(texts.error(for: .init(isValid: false, hasContent: true, wasBlurred: true)) == texts.formatError)
        // Corrected: cleared.
        #expect(texts.error(for: .init(isValid: true, hasContent: true, wasBlurred: true)) == nil)
        // Never touched: nothing. Left empty: required error, even back in focus.
        #expect(texts.error(for: .init()) == nil)
        #expect(texts.error(for: .init(wasBlurred: true)) == texts.requiredError)
        #expect(texts.error(for: .init(isFocused: true, wasBlurred: true)) == texts.requiredError)
    }

    @Test func helperTextShowsOnlyWhileFocused() {
        #expect(texts.message(for: .init(isFocused: true)) == texts.helperText)
        #expect(texts.message(for: .init()) == nil)
    }

    @Test func defaultsFollowTheLocaleAndTheMerchantWins() {
        #expect(CardFormTexts().resolved(locale: "fr-FR")[.cvv]?.label == "Cryptogramme")
        #expect(CardFormTexts().resolved(locale: "de-DE")[.cvv]?.label == "Security code")
        let own = CardFormTexts(cvv: .init(label: "CVC", helperText: " "))
        #expect(own.resolved(locale: "fr")[.cvv]?.label == "CVC")
        #expect(own.resolved(locale: "fr")[.cvv]?.helperText == nil)
        #expect(own.resolved(locale: "fr")[.cvv]?.formatError == "Cryptogramme invalide.")
    }
}
