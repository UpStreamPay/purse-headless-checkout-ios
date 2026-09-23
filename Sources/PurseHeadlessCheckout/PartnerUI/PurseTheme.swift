// Web: packages/partner-ui/src/commons/PartnerUI/theming
// Same: scopes global / input / label / helperText with :focus :invalid :valid, the fallback chain (scope variant → scope → global variant → global).
// Differs: native UIColor/UIFont, not CSS-like strings; `input` maps straight onto `SecureFieldsStyle`, `label`/`helperText` style the SDK's own `CardFormView`.

import UIKit

/// Styling for the surfaces the SDK renders itself.
public struct PurseTheme: Sendable {
    /// Web's `ThemeScope<'label' | 'helperText' | 'global'>`.
    public struct Text: Sendable {
        public var color: UIColor?
        public var font: UIFont?

        public init(color: UIColor? = nil, font: UIFont? = nil) {
            self.color = color
            self.font = font
        }

        fileprivate func over(_ base: Text?) -> Text {
            Text(color: color ?? base?.color, font: font ?? base?.font)
        }
    }

    /// Shaped to what `SecureFieldsStyle` can apply.
    public struct FieldStyle: Sendable {
        public var color: UIColor?
        public var placeholderColor: UIColor?
        public var backgroundColor: UIColor?
        public var font: UIFont?

        public init(
            color: UIColor? = nil,
            placeholderColor: UIColor? = nil,
            backgroundColor: UIColor? = nil,
            font: UIFont? = nil
        ) {
            self.color = color
            self.placeholderColor = placeholderColor
            self.backgroundColor = backgroundColor
            self.font = font
        }

        fileprivate func over(_ base: FieldStyle?) -> FieldStyle {
            FieldStyle(
                color: color ?? base?.color,
                placeholderColor: placeholderColor ?? base?.placeholderColor,
                backgroundColor: backgroundColor ?? base?.backgroundColor,
                font: font ?? base?.font
            )
        }
    }

    /// Every scope resolved — no `nil` left for the keys ``default`` defines.
    public struct Resolved: Sendable {
        public let input: FieldStyle
        public let inputFocus: FieldStyle
        public let inputInvalid: FieldStyle
        public let inputValid: FieldStyle
        public let label: Text
        public let labelInvalid: Text
        public let labelValid: Text
        public let helperText: Text
        public let helperTextInvalid: Text
        public let gap: CGFloat
    }

    /// What every scope falls back to (web `global`).
    public var global: Text?
    public var globalInvalid: Text?
    public var globalValid: Text?
    /// The secure card fields themselves (web `input`).
    public var input: FieldStyle?
    public var inputFocus: FieldStyle?
    public var inputInvalid: FieldStyle?
    public var inputValid: FieldStyle?
    /// Labels above each secure field (web `label`).
    public var label: Text?
    public var labelInvalid: Text?
    public var labelValid: Text?
    /// Help text under a field, and the error shown in its place (web `helperText`).
    public var helperText: Text?
    public var helperTextInvalid: Text?
    public var gap: CGFloat?

    public init(
        global: Text? = nil,
        globalInvalid: Text? = nil,
        globalValid: Text? = nil,
        input: FieldStyle? = nil,
        inputFocus: FieldStyle? = nil,
        inputInvalid: FieldStyle? = nil,
        inputValid: FieldStyle? = nil,
        label: Text? = nil,
        labelInvalid: Text? = nil,
        labelValid: Text? = nil,
        helperText: Text? = nil,
        helperTextInvalid: Text? = nil,
        gap: CGFloat? = nil
    ) {
        self.global = global
        self.globalInvalid = globalInvalid
        self.globalValid = globalValid
        self.input = input
        self.inputFocus = inputFocus
        self.inputInvalid = inputInvalid
        self.inputValid = inputValid
        self.label = label
        self.labelInvalid = labelInvalid
        self.labelValid = labelValid
        self.helperText = helperText
        self.helperTextInvalid = helperTextInvalid
        self.gap = gap
    }

    /// Web's `Theme.defaultTheme`, trimmed to the keys applied here.
    public static let `default` = PurseTheme(
        global: Text(color: UIColor(red: 0x1f / 255, green: 0x29 / 255, blue: 0x33 / 255, alpha: 1), font: .systemFont(ofSize: 14)),
        globalInvalid: Text(color: UIColor(red: 0xba / 255, green: 0x25 / 255, blue: 0x25 / 255, alpha: 1)),
        globalValid: Text(color: UIColor(red: 0x0f / 255, green: 0x86 / 255, blue: 0x13 / 255, alpha: 1)),
        input: FieldStyle(placeholderColor: UIColor(red: 0x61 / 255, green: 0x6e / 255, blue: 0x7c / 255, alpha: 1), backgroundColor: .clear),
        helperText: Text(font: .systemFont(ofSize: 12)),
        gap: 8
    )

    /// Web's `Theme.build()`: a key is read from the scope variant, then the scope, then the global
    /// variant, then global.
    public func resolve() -> Resolved {
        let merged = mergeOver(Self.default)
        let global = merged.global ?? Text()
        let globalInvalid = merged.globalInvalid ?? Text()
        let globalValid = merged.globalValid ?? Text()

        func text(_ scope: Text?, variant: Text? = nil, globalVariant: Text? = nil) -> Text {
            Text(
                color: variant?.color ?? scope?.color ?? globalVariant?.color ?? global.color,
                font: variant?.font ?? scope?.font ?? globalVariant?.font ?? global.font
            )
        }

        func field(_ scope: FieldStyle?, variant: FieldStyle? = nil, globalVariant: Text? = nil) -> FieldStyle {
            FieldStyle(
                color: variant?.color ?? scope?.color ?? globalVariant?.color ?? global.color,
                placeholderColor: variant?.placeholderColor ?? scope?.placeholderColor,
                backgroundColor: variant?.backgroundColor ?? scope?.backgroundColor,
                font: variant?.font ?? scope?.font ?? globalVariant?.font ?? global.font
            )
        }

        return Resolved(
            input: field(merged.input),
            inputFocus: field(merged.input, variant: merged.inputFocus),
            inputInvalid: field(merged.input, variant: merged.inputInvalid, globalVariant: globalInvalid),
            inputValid: field(merged.input, variant: merged.inputValid, globalVariant: globalValid),
            label: text(merged.label),
            labelInvalid: text(merged.label, variant: merged.labelInvalid, globalVariant: globalInvalid),
            labelValid: text(merged.label, variant: merged.labelValid, globalVariant: globalValid),
            helperText: text(merged.helperText),
            helperTextInvalid: text(merged.helperText, variant: merged.helperTextInvalid, globalVariant: globalInvalid),
            gap: merged.gap ?? Self.default.gap ?? 8
        )
    }

    /// `self` wins wherever it sets a value, `base` fills the rest.
    private func mergeOver(_ base: PurseTheme) -> PurseTheme {
        PurseTheme(
            global: global?.over(base.global) ?? base.global,
            globalInvalid: globalInvalid?.over(base.globalInvalid) ?? base.globalInvalid,
            globalValid: globalValid?.over(base.globalValid) ?? base.globalValid,
            input: input?.over(base.input) ?? base.input,
            inputFocus: inputFocus?.over(base.inputFocus) ?? base.inputFocus,
            inputInvalid: inputInvalid?.over(base.inputInvalid) ?? base.inputInvalid,
            inputValid: inputValid?.over(base.inputValid) ?? base.inputValid,
            label: label?.over(base.label) ?? base.label,
            labelInvalid: labelInvalid?.over(base.labelInvalid) ?? base.labelInvalid,
            labelValid: labelValid?.over(base.labelValid) ?? base.labelValid,
            helperText: helperText?.over(base.helperText) ?? base.helperText,
            helperTextInvalid: helperTextInvalid?.over(base.helperTextInvalid) ?? base.helperTextInvalid,
            gap: gap ?? base.gap
        )
    }
}

/// The card subset of web's `HostedFormUIOptions`. `nil` falls back to the SDK's own wording.
public struct CardFormTexts: Sendable {
    public var cardNumber: FieldTexts
    public var expDate: FieldTexts
    public var cvv: FieldTexts
    public var holderName: FieldTexts

    public init(
        cardNumber: FieldTexts = FieldTexts(),
        expDate: FieldTexts = FieldTexts(),
        cvv: FieldTexts = FieldTexts(),
        holderName: FieldTexts = FieldTexts()
    ) {
        self.cardNumber = cardNumber
        self.expDate = expDate
        self.cvv = cvv
        self.holderName = holderName
    }

    /// The texts one secure field can show. `requiredError` and `formatError` replace the helper
    /// text when the field is invalid.
    public struct FieldTexts: Sendable {
        public var label: String?
        public var placeholder: String?
        public var helperText: String?
        public var requiredError: String?
        public var formatError: String?

        public init(
            label: String? = nil,
            placeholder: String? = nil,
            helperText: String? = nil,
            requiredError: String? = nil,
            formatError: String? = nil
        ) {
            self.label = label
            self.placeholder = placeholder
            self.helperText = helperText
            self.requiredError = requiredError
            self.formatError = formatError
        }
    }
}
