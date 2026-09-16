import Foundation

/// The calls this demo makes against **alfred**, the `usp-widget` dev server holding the server-
/// side Purse credentials a real merchant backend would. None of this is SDK surface: minting a
/// session, looking one up and capturing are all merchant-backend concerns.
struct AlfredClient {

    struct Session {
        let widgetData: String
        /// The v2 ClientSession id, distinct from `payment_session.id`. Only a fallback default for
        /// the transactions lookup.
        let orchestrationSessionId: String?
    }

    let baseURL: String

    /// `ALFRED_BASE_URL` from `.env` via Info.plist, else the Simulator default. Android needs
    /// `10.0.2.2` because an emulator aliases the host that way; the Simulator shares the host's
    /// network stack, so `localhost` is right here.
    static var fromInfoPlist: String {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "ALFRED_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else { return "http://localhost:9001" }
        return configured.hasSuffix("/") ? String(configured.dropLast()) : configured
    }

    /// Two steps, as alfred's own demo site uses: 1. `GET /order` → alfred's demo legacy order,
    /// wrapped as `{ "order": … }`. 2.
    static let returnURL = "https://cdn.purse-dev.com/return/done.html"

    func createSession() async throws -> Session {
        let wrapper = try await getJSON("\(baseURL)/order")
        guard var order = wrapper["order"]?.raw as? [String: Any] else {
            throw DemoError("alfred's /order carried no order")
        }
        // The URLs sit on the **nested** `order.order`, not the wrapper alfred posts. Patching the
        // outer object adds keys nothing reads, and the session comes back pointing at localhost
        // anyway — verified by minting one and reading `shopper_redirection_url` back.
        if var inner = order["order"] as? [String: Any] {
            for key in ["redirection", "success", "failure"] {
                inner[key] = Self.returnURL
            }
            order["order"] = inner
        }
        let session = try await postJSON("\(baseURL)/orchestration_session", body: DemoJSON(raw: order))
        guard let data = session["widget"]?["data"]?.string else {
            throw DemoError("alfred's /orchestration_session carried no widget.data")
        }
        return Session(widgetData: data, orchestrationSessionId: session["id"]?.string)
    }

    /// `GET /payment_session/{id}` — behind "Get transactions", and the source of truth after a
    /// redirect return. Really a JSON **array**, one object per transaction, newest first.
    func paymentSession(id: String) async throws -> [DemoJSON] {
        let value = try await request("\(baseURL)/payment_session/\(id)", method: "GET", body: nil)
        guard let array = value.array else {
            throw DemoError("expected an array of transactions, got \(value.compact)")
        }
        return array
    }

    /// `POST /payments/{id}/capture`, for a `capture_mode: MANUAL` payment. `amountMinorUnits` is
    /// the API's integer amount (480 for 4.80).
    func capture(paymentId: String, amountMinorUnits: Int) async throws -> DemoJSON {
        try await postJSON(
            "\(baseURL)/payments/\(paymentId)/capture",
            body: .object(["amount": .number(Double(amountMinorUnits))])
        )
    }

    private func getJSON(_ url: String) async throws -> DemoJSON {
        try await request(url, method: "GET", body: nil)
    }

    private func postJSON(_ url: String, body: DemoJSON) async throws -> DemoJSON {
        try await request(url, method: "POST", body: body)
    }

    private func request(_ urlString: String, method: String, body: DemoJSON?) async throws -> DemoJSON {
        guard let url = URL(string: urlString) else { throw DemoError("not a usable URL: \(urlString)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body.rawObject)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DemoError("HTTP \(status) from \(urlString): \(String(decoding: data, as: UTF8.self))")
        }
        return try DemoJSON(data)
    }
}

struct DemoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
