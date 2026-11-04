import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Every ``PurseErrorCode`` the SDK can raise is produced by at least one ``PurseError``, each
/// carrying its code, a non-blank message and the shared documentation link.
struct PurseErrorCodeCoverageTests {

    private struct Boom: Error {}

    /// One `PurseError` per code, using whichever real case can carry it — several
    /// ``PurseCheckoutError`` cases take an explicit ``PurseErrorCode``.
    private func raised() -> [PurseErrorCode: any PurseError] {
        let boom = Boom()
        let values: [any PurseError] = [
            PurseCheckoutError.sessionExpired(sessionId: "s-1"),
            PurseSessionError.sessionMalformed("not json"),
            PurseSessionError.environmentNotAllowed(.test),
            PurseCheckoutError.submitBlocked(state: .submitting),
            PurseCheckoutError.checkoutTornDown,
            PurseCheckoutError.validateFailed("validate call failed", nil),
            PurseCheckoutError.hookFailed(hook: "onRedirection", underlying: boom, code: .postValidateFailed),
            PurseCheckoutError.paymentNotFulfilled("the split does not cover the amount to pay"),
            PurseCheckoutError.itemNotFulfilled(itemId: "purse-creditcard"),
            PurseCheckoutError.hookFailed(hook: "validateUI", underlying: boom, code: .uiValidationFailedError),
            PurseCheckoutError.hookFailed(hook: "onBeforeValidate", underlying: boom, code: .onBeforeValidateHookFailed),
            PurseCheckoutError.noPluginRegistered(itemId: "no plugin"),
            PurseCheckoutError.methodDisabled(itemId: "paypal-wallet", disabled: .submitting),
            PartnerUIError("Apple Pay failed: the sheet could not be presented"),
            PurseCheckoutError.secondaryTokenizationFailed("init failed", .failedToInitSecondaryToken),
            PurseCheckoutError.invalidSecondaryCard("cvv", .secondaryMethodRequiredCVV),
            PurseCheckoutError.invalidSecondaryCard("pan", .secondaryMethodWrongPANFormat),
            PurseCheckoutError.invalidSecondaryCard("cvv format", .secondaryMethodWrongCVVFormat),
            PurseCheckoutError.secondaryTokenizationFailed("empty", .secondaryTokenEmptyBalance),
            PurseCheckoutError.invalidTake("too much", .invalidTakeAmount),
            PurseCheckoutError.invalidTake("above max", .maxAmountReached),
            PurseCheckoutError.invalidTake("used up", .usageLimitError),
            PurseCheckoutError.walletOperationFailed("no wallet", .missingWalletSession),
            PurseCheckoutError.walletOperationFailed("no token", .missingToken),
            PurseCheckoutError.walletOperationFailed("wallet fetch", .setWalletSessionFailed),
            PurseCheckoutError.walletOperationFailed("bad name", .invalidTokenName),
            PurseCheckoutError.walletOperationFailed("taken", .tokenNameExists),
            PurseCheckoutError.walletOperationFailed("saved", .tokenNotRegisterable),
            PurseCheckoutError.walletOperationFailed("never", .methodNotRegisterable),
            PurseCheckoutError.walletOperationFailed("delete all", .failedToDeleteAllTokens),
            PurseCheckoutError.methodNotSimulable(itemId: "purse-creditcard"),
            PurseCheckoutError.loanSimulationFailed("no plugin_result", underlying: nil),
            PaymentAPIError("transport", status: nil, path: "/validate")
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.code, $0) })
    }

    @Test func everyCodeIsCoveredSharesTheRootAndLinksToItsDocumentation() {
        let raised = raised()

        // unknownError exists for web parity only — this SDK never raises an untyped error.
        let uncovered = Set(PurseErrorCode.allCases).subtracting(raised.keys)
        #expect(uncovered == [.unknownError])

        for (code, error) in raised {
            #expect(!error.message.isEmpty, "\(code) has a message")
            #expect(error.documentationLink == code.documentationLink)
            #expect(error.documentationLink.hasSuffix("#\(code.rawValue.lowercased())"))
        }
    }
}
