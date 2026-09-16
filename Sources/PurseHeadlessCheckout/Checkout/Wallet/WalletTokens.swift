// Web: packages/headless-checkout/src/headless-checkout.ts `setWalletSession`, `ensureEditionCapability`, `validateTokenName`.
// Same: the wallet's own token list gates edit / delete / favorite; label rule `^[a-zA-Z0-9\s]{1,25}$` + unique.
// Differs: nothing.

import Foundation

/// The wallet side of saved instruments: the client (when the widget data carried a `wallet_session`)
/// and its token list.
@MainActor
final class WalletTokens {

    private static let labelPattern = "^[a-zA-Z0-9\\s]{1,25}$"

    let client: WalletAPIClient?

    /// The wallet's own tokens, as last fetched.
    private(set) var tokens: [WalletAPIClient.WalletToken] = []

    init(params: PurseSessionParams, walletAPIRoot: String, urlSession: URLSession) {
        if let wallet = params.walletSession {
            client = WalletAPIClient(
                apiKey: params.apiKey,
                walletAPIRoot: walletAPIRoot,
                ownerReference: wallet.ownerReference,
                walletSessionId: wallet.sessionId,
                merchantId: wallet.merchant,
                session: urlSession
            )
        } else {
            client = nil
        }
    }

    func fetch() async throws -> [WalletAPIClient.WalletToken] {
        let client = try requireClient()
        let fetched = await client.getTokens()
        tokens = fetched
        return fetched
    }

    func forget(_ tokenId: String) {
        tokens.removeAll { $0.id == tokenId }
    }

    func clear() {
        tokens = []
    }

    func requireClient() throws -> WalletAPIClient {
        guard let client else {
            throw PurseCheckoutError.walletOperationFailed(
                "no wallet_session was attached to this checkout", .missingWalletSession
            )
        }
        return client
    }

    func requireToken(_ tokenId: String) throws {
        guard tokens.contains(where: { $0.id == tokenId }) else {
            throw PurseCheckoutError.walletOperationFailed(
                "token \(tokenId) is not present in the wallet", .missingToken
            )
        }
    }

    /// - Parameter takenNames: the labels already used by the session's tokens, other than the one
    ///   being renamed.
    func validateLabel(_ name: String, takenNames: [String], excludingTokenId: String?) throws {
        guard name.range(of: Self.labelPattern, options: .regularExpression) != nil else {
            throw PurseCheckoutError.walletOperationFailed(
                "invalid token name '\(name)' — 1-25 alphanumeric/space characters", .invalidTokenName
            )
        }
        let existsInWallet = tokens.contains { $0.id != excludingTokenId && $0.name == name }
        if takenNames.contains(name) || existsInWallet {
            throw PurseCheckoutError.walletOperationFailed(
                "a saved card is already named '\(name)'", .tokenNameExists
            )
        }
    }
}
