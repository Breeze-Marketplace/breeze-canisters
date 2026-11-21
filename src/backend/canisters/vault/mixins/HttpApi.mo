import Array "mo:core/Array";
import Nat16 "mo:core/Nat16";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Assets "mo:assets";
import AssetsTypes "mo:assets/Types";
import CertifiedAssets "mo:certified-assets";

import DeliveryToken "../../../lib/DeliveryToken";
import Delivery "../lib/Delivery";
import Visibility "../lib/Visibility";
import Types "../types";

/// HTTP serving: certified public assets, and private assets behind a delivery ticket (`?token=`,
/// checked by `Delivery.Gate`). Privacy is decided on the percent-decoded path, the one `mo:assets`
/// looks up.
mixin (
    assets : Assets.Assets,
    certs : CertifiedAssets.CertifiedAssets,
    gate : Delivery.Gate,
) {
    public query func http_request(request : AssetsTypes.HttpRequest) : async Types.HttpResponse {
        let requestPath = DeliveryToken.extractRequestPath(request.url);
        if (requestPath == "/") return deniedResponse(404);
        let ?decodedPath = Visibility.decodePath(requestPath) else return deniedResponse(400);

        if (Visibility.isPrivate(decodedPath)) {
            return ticketedResponse(request, requestPath, decodedPath, false);
        };
        certifiedAssetResponse(request, null);
    };

    /// Serves a private asset and consumes its ticket. No `http_request` asks for an upgrade, so only
    /// direct callers get here.
    public func http_request_update(request : AssetsTypes.HttpRequest) : async Types.HttpResponse {
        let requestPath = DeliveryToken.extractRequestPath(request.url);
        let ?decodedPath = Visibility.decodePath(requestPath) else return deniedResponse(400);
        if (not Visibility.isPrivate(decodedPath)) return deniedResponse(404);
        ticketedResponse(request, requestPath, decodedPath, true);
    };

    /// Public assets stream freely. A private asset's token carries its ticket (see
    /// `Visibility.keyWithTicket`), checked again for every chunk.
    public query func http_request_streaming_callback(token : AssetsTypes.StreamingCallbackToken) : async Types.StreamingCallbackHttpResponse {
        let (key, ticket) = Visibility.splitTicketKey(token.key);
        if (not Visibility.isPrivate(key)) {
            return assets.http_request_streaming_callback({ token with key });
        };
        let ?t = ticket else Runtime.trap("Access denied");
        switch (gate.validateContinuation(t, key)) {
            case (#err(_)) Runtime.trap("Access denied");
            case (#ok(_)) {};
        };
        let response = assets.http_request_streaming_callback({ token with key });
        {
            response with token = switch (response.token) {
                case (?next) ?{
                    next with key = Visibility.keyWithTicket(next.key, t)
                };
                case null null;
            }
        };
    };

    func ticketedResponse(request : AssetsTypes.HttpRequest, requestPath : Text, decodedPath : Text, consumeNonce : Bool) : Types.HttpResponse {
        let ?ticket = Delivery.queryToken(request.url) else return deniedResponse(404);
        switch (gate.validate(ticket, decodedPath, consumeNonce)) {
            case (#err(_)) deniedResponse(403);
            case (#ok(_)) {
                let response = certifiedAssetResponse({ request with url = requestPath }, ?ticket);
                {
                    response with headers = response.headers.concat([("Content-Disposition", "attachment")])
                };
            };
        };
    };

    func deniedResponse(statusCode : Nat16) : Types.HttpResponse {
        {
            status_code = statusCode;
            headers = [("content-type", "text/plain")];
            body = "Access denied".encodeUtf8();
            streaming_strategy = null;
            upgrade = null;
        };
    };

    /// `ticket` is set for a private asset, so a streamed download can carry it to the callback.
    func certifiedAssetResponse(request : AssetsTypes.HttpRequest, ticket : ?Text) : Types.HttpResponse {
        let response = assets.http_request(request);

        let res : CertifiedAssets.HttpResponse = {
            status_code = response.status_code;
            headers = response.headers;
            body = response.body;
            streaming_strategy = null;
            upgrade = null;
        };
        let headers : [AssetsTypes.HeaderField] = switch (certs.get_certified_response({ request with certificate_version = ?(1 : Nat16) }, res, null)) {
            case (#ok(certified)) { res.headers.concat(certified.headers) };
            case (#err(_)) { res.headers };
        };

        {
            status_code = response.status_code;
            headers;
            body = response.body;
            streaming_strategy = switch (response.streaming_strategy) {
                case (?#Callback(cb)) {
                    let token = switch (ticket) {
                        case (?t) {
                            {
                                cb.token with key = Visibility.keyWithTicket(cb.token.key, t)
                            };
                        };
                        case null cb.token;
                    };
                    ?#Callback({
                        callback = http_request_streaming_callback;
                        token;
                    });
                };
                case null { null };
            };
            upgrade = null;
        };
    };
};
