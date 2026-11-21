import Prim "mo:⛔";
import Array "mo:core/Array";
import Error "mo:core/Error";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";

import Management "../../../../interfaces/management";
import Checkout "Checkout";

/// Stripe API calls over HTTPS outcalls (BRE-123). Every response goes through `transform`, which
/// reduces it to a Candid-encoded `Checkout.Reply`, so replicas agree on it and the shop reads only
/// what it uses.
///
/// The merchant's restricted key travels in the `Authorization` header to every node that makes the
/// call, and sits in shop state that node operators can read; that is why only restricted keys are
/// accepted (`Checkout.validateKey`). The IC bounds every outcall (30s for Stripe to answer, 60s for
/// the subnet), so a silent Stripe can't hold the shop up.
module Stripe {
    let API = "https://api.stripe.com/v1";

    /// Covers Stripe's response headers (about 1–2 KB) and a Checkout Session body with room to spare.
    let MAX_RESPONSE_BYTES : Nat64 = 24_000;

    /// The name of the shop's public transform query, counted in the outcall's request size.
    public let TRANSFORM_METHOD = "stripeTransform";

    /// The transform the shop exposes as `stripeTransform`: drops the headers and replaces the body
    /// with the Candid encoding of what `Checkout.parseReply` read from it.
    public func transform(response : Management.HttpRequestResult) : Management.HttpRequestResult {
        let body = switch (Text.decodeUtf8(response.body)) {
            case (?text) text;
            case null "";
        };
        let reply : Checkout.Reply = Checkout.parseReply(response.status, body);
        { status = response.status; headers = []; body = to_candid (reply) };
    };

    type Request = {
        key : Text;
        method : { #get; #post };
        path : Text;
        form : ?Text;
        idempotencyKey : ?Text;
        /// False sends the request from one node: for a create, which mustn't run once per replica.
        replicated : Bool;
    };

    func send(request : Request, transformFunction : Management.TransformFunction) : async* Checkout.Reply {
        let url = API # request.path;
        var headers = [
            { name = "Authorization"; value = Checkout.basicAuth(request.key) },
            { name = "User-Agent"; value = "breeze-shop" },
        ];
        switch (request.form) {
            case (?_) headers := headers.concat([{
                name = "Content-Type";
                value = "application/x-www-form-urlencoded";
            }]);
            case null {};
        };
        switch (request.idempotencyKey) {
            case (?key) headers := headers.concat([{
                name = "Idempotency-Key";
                value = key;
            }]);
            case null {};
        };
        let body = switch (request.form) {
            case (?form) ?form.encodeUtf8();
            case null null;
        };
        let args : Management.HttpRequestArgs = {
            url;
            max_response_bytes = ?MAX_RESPONSE_BYTES;
            method = request.method;
            headers;
            body;
            transform = ?{ function = transformFunction; context = "" };
            is_replicated = ?request.replicated;
        };
        var requestSize = url.encodeUtf8().size() + TRANSFORM_METHOD.size();
        for (header in headers.values()) {
            requestSize += header.name.encodeUtf8().size() + header.value.encodeUtf8().size();
        };
        switch (body) {
            case (?b) requestSize += b.size();
            case null {};
        };
        let cycles = Prim.costHttpRequest(Nat64.fromNat(requestSize), MAX_RESPONSE_BYTES);
        let result = try {
            await (with cycles) Management.getManagementCanister().http_request(args);
        } catch (e) {
            return #error({
                status = 0;
                message = "Couldn't reach Stripe: " # Error.message(e);
            });
        };
        let reply : ?Checkout.Reply = from_candid (result.body);
        switch (reply) {
            case (?r) r;
            case null #error({
                status = result.status;
                message = "Couldn't read Stripe's reply";
            });
        };
    };

    /// Creates a Checkout Session. Sent from one node, since a create must not run once per replica;
    /// the caller confirms what Stripe created with `retrieveSession`, which all replicas agree on.
    public func createSession(
        key : Text,
        request : Checkout.SessionRequest,
        idempotencyKey : Text,
        transformFunction : Management.TransformFunction,
    ) : async* Checkout.Reply {
        await* send(
            {
                key;
                method = #post;
                path = "/checkout/sessions";
                form = ?Checkout.formEncode(Checkout.sessionForm(request));
                idempotencyKey = ?idempotencyKey;
                replicated = false;
            },
            transformFunction,
        );
    };

    /// Reads a Checkout Session. Replicated, so the subnet agrees on what Stripe says.
    public func retrieveSession(
        key : Text,
        sessionId : Text,
        transformFunction : Management.TransformFunction,
    ) : async* Checkout.Reply {
        await* send(
            {
                key;
                method = #get;
                path = "/checkout/sessions/" # Checkout.percentEncode(sessionId);
                form = null;
                idempotencyKey = null;
                replicated = true;
            },
            transformFunction,
        );
    };

    /// Lists one Checkout Session: succeeds only if `key` is valid and may read Checkout Sessions.
    public func checkKey(key : Text, transformFunction : Management.TransformFunction) : async* Checkout.Reply {
        await* send(
            {
                key;
                method = #get;
                path = "/checkout/sessions?limit=1";
                form = null;
                idempotencyKey = null;
                replicated = true;
            },
            transformFunction,
        );
    };
};
