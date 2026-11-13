import SwiftUI

/// Deliberately greyscale, so nothing competes with the partners' own branded controls or suggests
/// a Purse colour to a merchant. Only the outcome colours below carry hue.
enum DemoTheme {
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let accentTint = Color(uiColor: .label)

    /// Material 3 ships only `error`, so success and "unconfirmed" are defined here.
    static let success = Color(red: 0.06, green: 0.48, blue: 0.30)
    static let warning = Color(red: 0.54, green: 0.35, blue: 0.00)
    static let failure = Color(uiColor: .systemRed)

    static let mono = Font.system(.footnote, design: .monospaced)
}

/// Two decimals always — a `Decimal` of 480 must not read "480 EUR" next to "42.5 EUR".
func amountText(_ amount: Decimal, _ currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let text = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    return "\(text) \(currency)"
}
