import Array "mo:core/Array";
import Base64 "mo:core/Base64";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import { type Result } "mo:core/Result";
import Text "mo:core/Text";

import Json "Json";

/// The pure part of Stripe Checkout (BRE-123): restricted-key checks, the form body that creates
/// a session, reading Stripe's replies, and deciding whether a session pays an order. No calls, so
/// it runs under `mops test`; `lib.mo` makes the HTTPS outcalls.
module Checkout {
    public type Mode = { #test; #live };

    /// Accepts only a restricted key (`rk_test_…`/`rk_live_…`). A secret key (`sk_…`) can refund,
    /// pay out and read every customer, and node operators can read shop state, so it's refused.
    public func validateKey(key : Text) : Result<Mode, Text> {
        if (key.startsWith(#text "sk_")) {
            return #err("That's a secret key. Create a restricted key (rk_…) with write access to Checkout Sessions only, and paste that instead.");
        };
        if (key.startsWith(#text "pk_")) {
            return #err("That's a publishable key. Create a restricted key (rk_…) with write access to Checkout Sessions only.");
        };
        let mode : Mode = if (key.startsWith(#text "rk_live_")) #live else if (key.startsWith(#text "rk_test_")) #test else {
            return #err("A Stripe restricted key starts with rk_live_ or rk_test_.");
        };
        if (key.size() < 20 or key.size() > 512) {
            return #err("That doesn't look like a complete Stripe key.");
        };
        for (c in key.chars()) {
            if (not (Char.isAlphabetic(c) or Char.isDigit(c) or c == '_') or Char.toNat32(c) > 0x7F) {
                return #err("A Stripe key contains only letters, digits and underscores.");
            };
        };
        #ok(mode);
    };

    /// The last four characters of `key`, to show the merchant which key is set.
    public func keyHint(key : Text) : Text {
        let chars = key.toArray();
        let n = chars.size();
        if (n <= 4) return key;
        Text.fromArray(chars.sliceToArray(n - 4, n));
    };

    /// The `Authorization` header value: HTTP Basic with the key as user name and no password.
    public func basicAuth(key : Text) : Text {
        "Basic " # Base64.encode((key # ":").encodeUtf8());
    };

    /// Percent-encodes `text` for `application/x-www-form-urlencoded`: every byte of its UTF-8 form
    /// except the unreserved characters (letters, digits, `-._~`).
    public func percentEncode(text : Text) : Text {
        var out = "";
        for (byte in text.encodeUtf8().values()) {
            let c = Char.fromNat32(byte.toNat32());
            if ((byte >= 0x30 and byte <= 0x39) or (byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A) or c == '-' or c == '.' or c == '_' or c == '~') {
                out #= Char.toText(c);
            } else {
                out #= "%" # hexByte(byte);
            };
        };
        out;
    };

    func hexByte(byte : Nat8) : Text {
        let digits = "0123456789ABCDEF".toArray();
        let n = byte.toNat();
        Char.toText(digits[n / 16]) # Char.toText(digits[n % 16]);
    };

    public func formEncode(pairs : [(Text, Text)]) : Text {
        pairs.values().map(func((k, v) : (Text, Text)) : Text = percentEncode(k) # "=" # percentEncode(v)).join("&");
    };

    /// Session lifetime asked of Stripe: its 30-minute minimum, plus a minute for the request to
    /// reach Stripe.
    public let SESSION_SECONDS : Nat = 1_860;

    /// How long after its session expires a card order is settled, so Stripe has finished
    /// completing or expiring the session by then.
    public let SETTLE_DELAY_NANOS : Int = 120_000_000_000;

    public type LineItem = {
        name : Text;
        /// In the currency's minor units (cents for USD).
        unitAmount : Nat;
        quantity : Nat;
    };

    public type SessionRequest = {
        orderId : Nat32;
        shopId : Text;
        /// Lowercase ISO code, e.g. "usd".
        currency : Text;
        items : [LineItem];
        successUrl : Text;
        cancelUrl : Text;
        /// Unix seconds; Stripe requires 30 minutes to 24 hours after it receives the request.
        expiresAtSeconds : Nat;
    };

    /// Stripe's limit on a product name.
    let MAX_PRODUCT_NAME = 250;

    /// The form fields that create a card-only, one-off payment session for an order. Card only, so
    /// a completed session is always paid or failed, never an asynchronous payment still settling.
    public func sessionForm(request : SessionRequest) : [(Text, Text)] {
        let fields = List.fromArray<(Text, Text)>([
            ("mode", "payment"),
            ("payment_method_types[0]", "card"),
            ("success_url", request.successUrl),
            ("cancel_url", request.cancelUrl),
            ("client_reference_id", Nat32.toText(request.orderId)),
            ("metadata[order_id]", Nat32.toText(request.orderId)),
            ("metadata[shop_id]", request.shopId),
            ("expires_at", Nat.toText(request.expiresAtSeconds)),
        ]);
        var i = 0;
        for (item in request.items.values()) {
            let prefix = "line_items[" # Nat.toText(i) # "]";
            List.add(fields, (prefix # "[price_data][currency]", request.currency));
            List.add(fields, (prefix # "[price_data][product_data][name]", truncate(item.name, MAX_PRODUCT_NAME)));
            List.add(fields, (prefix # "[price_data][unit_amount]", Nat.toText(item.unitAmount)));
            List.add(fields, (prefix # "[quantity]", Nat.toText(item.quantity)));
            i += 1;
        };
        List.toArray(fields);
    };

    func truncate(text : Text, max : Nat) : Text {
        let chars = text.toArray();
        if (chars.size() <= max) text else Text.fromArray(chars.sliceToArray(0, max));
    };

    /// The fields of a Checkout Session this shop reads.
    public type Session = {
        id : Text;
        /// "open", "complete" or "expired".
        status : Text;
        /// "paid", "unpaid" or "no_payment_required".
        paymentStatus : Text;
        amountTotal : ?Nat;
        currency : ?Text;
        clientReferenceId : ?Text;
        /// `metadata.shop_id`, set by `sessionForm`.
        shopId : ?Text;
        /// Where the buyer pays; present while the session is open.
        url : ?Text;
        livemode : Bool;
    };

    /// What a Stripe call returned, reduced to what the shop reads. The outcall transform turns
    /// every response into one of these, so all replicas agree on it whatever headers Stripe sent.
    public type Reply = {
        #session : Session;
        /// A list (any `"object": "list"`), only checked for success.
        #list;
        #error : { status : Nat; message : Text };
    };

    /// Reads the HTTP `status` and `body` of a Stripe reply.
    public func parseReply(status : Nat, body : Text) : Reply {
        let json = Json.parse(body);
        if (status < 200 or status >= 300) {
            let message = switch (json) {
                case (?value) {
                    switch (Json.field(value, "error")) {
                        case (?error) switch (Json.text(error, "message")) {
                            case (?m) m;
                            case null "Stripe returned HTTP " # Nat.toText(status);
                        };
                        case null "Stripe returned HTTP " # Nat.toText(status);
                    };
                };
                case null "Stripe returned HTTP " # Nat.toText(status);
            };
            return #error({ status; message });
        };
        let ?value = json else return #error({
            status;
            message = "Stripe's reply wasn't valid JSON";
        });
        switch (Json.text(value, "object")) {
            case (?"list") #list;
            case (?"checkout.session") {
                switch (Json.text(value, "id"), Json.text(value, "status"), Json.text(value, "payment_status")) {
                    case (?id, ?sessionStatus, ?paymentStatus) {
                        #session({
                            id;
                            status = sessionStatus;
                            paymentStatus;
                            amountTotal = Json.nat(value, "amount_total");
                            currency = Json.text(value, "currency");
                            clientReferenceId = Json.text(value, "client_reference_id");
                            shopId = switch (Json.field(value, "metadata")) {
                                case (?metadata) Json.text(metadata, "shop_id");
                                case null null;
                            };
                            url = Json.text(value, "url");
                            livemode = Json.bool(value, "livemode") == ?true;
                        });
                    };
                    case _ #error({
                        status;
                        message = "Stripe's checkout session is missing its id or status";
                    });
                };
            };
            case _ #error({ status; message = "Unexpected reply from Stripe" });
        };
    };

    /// What the shop expects of the session that pays an order.
    public type Expected = {
        sessionId : Text;
        orderId : Nat32;
        shopId : Text;
        currency : Text;
        amount : Nat;
    };

    public type Outcome = {
        #paid;
        #open;
        #expired;
        /// Completed but not yet paid; doesn't happen with card-only sessions.
        #pending;
        /// The session isn't the one that pays this order (wrong order, shop, amount or currency).
        #mismatch : Text;
    };

    /// Whether `session` pays the order described by `expected`. A session is only trusted as
    /// payment when it names this order and shop and charged exactly the order total.
    public func outcome(session : Session, expected : Expected) : Outcome {
        if (session.id != expected.sessionId) return #mismatch("session " # session.id # " isn't the order's session " # expected.sessionId);
        if (session.clientReferenceId != ?Nat32.toText(expected.orderId)) return #mismatch("session belongs to another order");
        if (session.shopId != ?expected.shopId) return #mismatch("session belongs to another shop");
        if (session.currency != ?expected.currency) return #mismatch("session currency differs from the order's");
        if (session.amountTotal != ?expected.amount) return #mismatch("session amount differs from the order total");
        switch (session.status, session.paymentStatus) {
            case ("complete", "paid") #paid;
            case ("complete", _) #pending;
            case ("open", _) #open;
            case ("expired", _) #expired;
            case (other, _) #mismatch("unknown session status " # other);
        };
    };

    public let MAX_RETURN_URL = 2048;

    /// True for an `https://` URL, or `http://` to localhost, 127.0.0.1 or a `*.localhost` host
    /// (local development). The buyer's browser is sent there after paying or cancelling.
    public func isAllowedReturnUrl(url : Text) : Bool {
        if (url.size() == 0 or url.size() > MAX_RETURN_URL) return false;
        for (c in url.chars()) {
            if (Char.isWhitespace(c) or Char.toNat32(c) < 0x20) return false;
        };
        if (url.startsWith(#text "https://")) return url.size() > "https://".size();
        let ?rest = url.stripStart(#text "http://") else return false;
        let ?hostAndPort = rest.split(#predicate(func(c) = c == '/' or c == '?' or c == '#')).next() else return false;
        let ?host = hostAndPort.split(#char ':').next() else return false;
        host == "localhost" or host == "127.0.0.1" or (host.endsWith(#text ".localhost") and host.size() > ".localhost".size());
    };

    /// A shop-wide cap on Stripe calls, so outsiders can't spend the shop's cycles on outcalls
    /// faster than `CALLS_PER_MINUTE`.
    public type Budget = { var windowStart : Int; var calls : Nat };

    public let CALLS_PER_MINUTE = 60;
    let MINUTE_NANOS : Int = 60_000_000_000;

    public func newBudget() : Budget = { var windowStart = 0; var calls = 0 };

    /// Takes one call from `budget` at `now`; false when this minute's calls are used up.
    public func takeCall(budget : Budget, now : Int) : Bool {
        if (now - budget.windowStart >= MINUTE_NANOS) {
            budget.windowStart := now;
            budget.calls := 0;
        };
        if (budget.calls >= CALLS_PER_MINUTE) return false;
        budget.calls += 1;
        true;
    };
};
