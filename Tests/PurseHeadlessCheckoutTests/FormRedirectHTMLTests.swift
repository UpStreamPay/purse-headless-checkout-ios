import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The auto-submitting form a POST redirect is delivered through.
struct FormRedirectHTMLTests {

    @Test func parsesAQueryString() {
        let fields = FormRedirectHTML.parseFormFields("PaReq=abc&MD=order-1&TermUrl=https%3A%2F%2Fshop.example%2Freturn")

        #expect(fields.count == 3)
        #expect(fields[0] == ("PaReq", "abc"))
        #expect(fields[1] == ("MD", "order-1"))
        // Percent-encoding is undone, or the ACS receives a literal `%3A`.
        #expect(fields[2] == ("TermUrl", "https://shop.example/return"))
    }

    /// `+` means a space in `application/x-www-form-urlencoded` — `removingPercentEncoding` alone
    /// does not know that.
    @Test func decodesPlusAsSpace() {
        #expect(FormRedirectHTML.parseFormFields("name=Jane+Doe")[0] == ("name", "Jane Doe"))
    }

    @Test func parsesJSONAndFlattensOneLevelOfNesting() {
        let fields = FormRedirectHTML.parseFormFields(#"{"PaReq":"abc","card":{"bin":"411111","last4":"1111"}}"#)
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })

        #expect(byName["PaReq"] == "abc")
        #expect(byName["card[bin]"] == "411111")
        #expect(byName["card[last4]"] == "1111")
    }

    /// A PSP's form field can carry an amount, and `12345678901234567.89` through a `Double` comes
    /// back as `12345678901234568`.
    @Test func numbersSurviveWithoutGoingThroughADouble() {
        #expect(FormRedirectHTML.parseFormFields(#"{"amount":12345678901234567.89}"#)[0]
            == ("amount", "12345678901234567.89"))
        #expect(FormRedirectHTML.parseFormFields(#"{"amount":42.50}"#)[0] == ("amount", "42.5"))
    }

    @Test func buildsAFormThatSubmitsItself() {
        let html = FormRedirectHTML.autoSubmitting(
            actionURL: "https://acs.bank.example/3ds",
            dataString: "PaReq=abc"
        )

        #expect(html.contains(#"<form method="POST" action="https://acs.bank.example/3ds">"#))
        #expect(html.contains(#"<input type="hidden" name="PaReq" value="abc">"#))
        #expect(html.contains("document.forms[0].submit()"))
    }

    /// A field value carrying markup must not be able to close the input and inject its own.
    @Test func escapesValuesThatWouldBreakOutOfTheAttribute() {
        let html = FormRedirectHTML.autoSubmitting(
            actionURL: "https://acs.bank.example/3ds",
            dataString: #"{"PaReq":"\"><script>alert(1)</script>"}"#
        )

        #expect(!html.contains("<script>"))
        #expect(html.contains("&quot;&gt;&lt;script&gt;"))
    }
}
