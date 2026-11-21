import { suite; test } "mo:test";

import Checkout "../stripe/Checkout";
import Json "../stripe/Json";
import Nat "mo:core/Nat";

let liveKey = "rk_live_51AbCdEfGhIjKlMnOp1234";
let testKey = "rk_test_51AbCdEfGhIjKlMnOp5678";

suite(
    "Checkout.validateKey",
    func() {
        test(
            "accepts restricted keys and reports their mode",
            func() {
                assert Checkout.validateKey(liveKey) == #ok(#live);
                assert Checkout.validateKey(testKey) == #ok(#test);
            },
        );
        test(
            "refuses secret, publishable and malformed keys",
            func() {
                for (key in ["sk_live_51AbCdEfGhIjKlMnOp1234", "pk_live_51AbCdEfGhIjKlMnOp1234", "rk_live_", "rk_live_short", "hello", "rk_live_51AbCdEf GhIjKlMnOp", "rk_live_51AbCdEf-GhIjKlMnOp", ""].values()) {
                    switch (Checkout.validateKey(key)) {
                        case (#ok(_)) assert false;
                        case (#err(_)) {};
                    };
                };
            },
        );
        test(
            "shows only the last four characters",
            func() {
                assert Checkout.keyHint(liveKey) == "1234";
                assert Checkout.keyHint("abc") == "abc";
            },
        );
    },
);

suite(
    "Checkout request encoding",
    func() {
        test(
            "authenticates with the key as the Basic user name and no password",
            func() {
                assert Checkout.basicAuth("rk_test_abc123") == "Basic cmtfdGVzdF9hYmMxMjM6";
            },
        );
        test(
            "percent-encodes everything but unreserved characters, byte by byte",
            func() {
                assert Checkout.percentEncode("Salt & Pepper") == "Salt%20%26%20Pepper";
                assert Checkout.percentEncode("a-b_c.d~Z9") == "a-b_c.d~Z9";
                assert Checkout.percentEncode("line_items[0][quantity]") == "line_items%5B0%5D%5Bquantity%5D";
                assert Checkout.percentEncode("café") == "caf%C3%A9";
                assert Checkout.percentEncode("https://x.io/ok?id={CHECKOUT_SESSION_ID}") == "https%3A%2F%2Fx.io%2Fok%3Fid%3D%7BCHECKOUT_SESSION_ID%7D";
                assert Checkout.percentEncode("a+b=c") == "a%2Bb%3Dc";
            },
        );
        test(
            "joins form fields with & and =",
            func() {
                assert Checkout.formEncode([("a", "1"), ("b c", "x&y")]) == "a=1&b%20c=x%26y";
                assert Checkout.formEncode([]) == "";
            },
        );
        test(
            "builds a card-only payment session with one entry per line item",
            func() {
                let fields = Checkout.sessionForm({
                    orderId = 42;
                    shopId = "aaaaa-aa";
                    currency = "usd";
                    items = [
                        { name = "Mug"; unitAmount = 1250; quantity = 2 },
                        { name = "Tee & Hat"; unitAmount = 3000; quantity = 1 },
                    ];
                    successUrl = "https://shop.example/ok";
                    cancelUrl = "https://shop.example/cancel";
                    expiresAtSeconds = 1_800_000_000;
                });
                let has = func(k : Text, v : Text) : Bool {
                    for ((fk, fv) in fields.values()) {
                        if (fk == k and fv == v) return true;
                    };
                    false;
                };
                assert has("mode", "payment");
                assert has("payment_method_types[0]", "card");
                assert has("client_reference_id", "42");
                assert has("metadata[order_id]", "42");
                assert has("metadata[shop_id]", "aaaaa-aa");
                assert has("expires_at", "1800000000");
                assert has("success_url", "https://shop.example/ok");
                assert has("line_items[0][price_data][currency]", "usd");
                assert has("line_items[0][price_data][unit_amount]", "1250");
                assert has("line_items[0][quantity]", "2");
                assert has("line_items[1][price_data][product_data][name]", "Tee & Hat");
                assert has("line_items[1][quantity]", "1");
                assert not has("line_items[2][quantity]", "1");
            },
        );
    },
);

let sessionJson = "{\"id\":\"cs_test_a1\",\"object\":\"checkout.session\",\"amount_total\":5500,\"currency\":\"usd\",\"client_reference_id\":\"42\",\"livemode\":false,\"metadata\":{\"order_id\":\"42\",\"shop_id\":\"aaaaa-aa\"},\"payment_status\":\"paid\",\"status\":\"complete\",\"url\":null,\"line_items\":null,\"custom_fields\":[],\"total_details\":{\"amount_discount\":0,\"amount_tax\":0}}";

let expected : Checkout.Expected = {
    sessionId = "cs_test_a1";
    orderId = 42;
    shopId = "aaaaa-aa";
    currency = "usd";
    amount = 5500;
};

func session() : Checkout.Session {
    switch (Checkout.parseReply(200, sessionJson)) {
        case (#session(s)) s;
        case _ { assert false; loop {} };
    };
};

suite(
    "Checkout.parseReply",
    func() {
        test(
            "reads the session fields the shop uses",
            func() {
                let s = session();
                assert s.id == "cs_test_a1";
                assert s.status == "complete";
                assert s.paymentStatus == "paid";
                assert s.amountTotal == ?5500;
                assert s.currency == ?"usd";
                assert s.clientReferenceId == ?"42";
                assert s.shopId == ?"aaaaa-aa";
                assert s.url == null;
                assert not s.livemode;
            },
        );
        test(
            "reads Stripe's error message from a failed call",
            func() {
                let body = "{\"error\":{\"message\":\"Invalid API Key provided: rk_test_****1234\",\"type\":\"invalid_request_error\"}}";
                assert Checkout.parseReply(401, body) == #error({
                    status = 401;
                    message = "Invalid API Key provided: rk_test_****1234";
                });
                assert Checkout.parseReply(500, "<html>") == #error({
                    status = 500;
                    message = "Stripe returned HTTP 500";
                });
            },
        );
        test(
            "recognises a list and rejects anything else",
            func() {
                assert Checkout.parseReply(200, "{\"object\":\"list\",\"data\":[],\"has_more\":false}") == #list;
                switch (Checkout.parseReply(200, "not json")) {
                    case (#error(_)) {};
                    case _ assert false;
                };
                switch (Checkout.parseReply(200, "{\"object\":\"checkout.session\",\"id\":\"cs_1\"}")) {
                    case (#error(_)) {};
                    case _ assert false;
                };
            },
        );
    },
);

suite(
    "Checkout.outcome",
    func() {
        test(
            "is paid only when the session is complete, paid and matches the order",
            func() {
                assert Checkout.outcome(session(), expected) == #paid;
                assert Checkout.outcome({ session() with status = "open"; paymentStatus = "unpaid" }, expected) == #open;
                assert Checkout.outcome({ session() with status = "expired"; paymentStatus = "unpaid" }, expected) == #expired;
                assert Checkout.outcome({ session() with paymentStatus = "unpaid" }, expected) == #pending;
            },
        );
        test(
            "refuses a session for another order, shop, amount, currency or id",
            func() {
                let mismatches = [
                    { session() with clientReferenceId = ?"43" },
                    { session() with shopId = ?"other" },
                    { session() with shopId = null },
                    { session() with amountTotal = ?5499 },
                    { session() with amountTotal = null },
                    { session() with currency = ?"eur" },
                    { session() with id = "cs_test_other" },
                ];
                for (s in mismatches.values()) {
                    switch (Checkout.outcome(s, expected)) {
                        case (#mismatch(_)) {};
                        case _ assert false;
                    };
                };
            },
        );
    },
);

suite(
    "Checkout.isAllowedReturnUrl",
    func() {
        test(
            "allows https and local http",
            func() {
                for (url in ["https://shop.example/orders/1", "http://localhost:3000/ok", "http://127.0.0.1:8000/x", "http://abc-cai.localhost:8000/orders?x=1", "http://localhost"].values()) {
                    assert Checkout.isAllowedReturnUrl(url);
                };
            },
        );
        test(
            "refuses other schemes, remote http, whitespace and empty hosts",
            func() {
                for (url in ["http://shop.example/ok", "javascript:alert(1)", "ftp://x", "", "https://", "https://shop.example/a b", "http://.localhost/", "http://evil.example?x=.localhost", "http://localhost.evil.example/"].values()) {
                    assert not Checkout.isAllowedReturnUrl(url);
                };
            },
        );
    },
);

suite(
    "Checkout.takeCall",
    func() {
        test(
            "allows CALLS_PER_MINUTE calls a minute",
            func() {
                let budget = Checkout.newBudget();
                let start = 1_000_000_000_000;
                var allowed = 0;
                for (_ in Nat.range(0, Checkout.CALLS_PER_MINUTE + 5)) {
                    if (Checkout.takeCall(budget, start)) allowed += 1;
                };
                assert allowed == Checkout.CALLS_PER_MINUTE;
                assert not Checkout.takeCall(budget, start + 59_000_000_000);
                assert Checkout.takeCall(budget, start + 60_000_000_000);
            },
        );
    },
);

suite(
    "Json.parse",
    func() {
        test(
            "reads nested values, escapes and surrogate pairs",
            func() {
                let ?value = Json.parse(" { \"a\" : [1, -2.5e3, true, false, null], \"b\": {\"c\": \"x\\\"y\\\\z\\n\\u00e9\\ud83d\\ude00\"} } ") else {
                    assert false;
                    return;
                };
                assert Json.field(value, "a") == ?#array([#number("1"), #number("-2.5e3"), #bool(true), #bool(false), #null_]);
                let ?b = Json.field(value, "b") else { assert false; return };
                assert Json.text(b, "c") == ?"x\"y\\z\né😀";
                assert Json.nat(value, "a") == null;
                assert Json.field(value, "missing") == null;
            },
        );
        test(
            "rejects invalid JSON",
            func() {
                for (text in ["", "{", "{\"a\":}", "[1,]", "{\"a\":1}x", "\"\\ud83d\"", "\"\\q\"", "tru", "{a:1}"].values()) {
                    assert Json.parse(text) == null;
                };
            },
        );
        test(
            "rejects nesting deeper than its limit",
            func() {
                var deep = "1";
                for (_ in Nat.range(0, 40)) { deep := "[" # deep # "]" };
                assert Json.parse(deep) == null;
            },
        );
    },
);
