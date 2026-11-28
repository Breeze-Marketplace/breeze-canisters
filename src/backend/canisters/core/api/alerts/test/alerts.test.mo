import { expect; suite; test } "mo:test";

import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import AlertsAPI "../lib";

let staff = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let other = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
let user = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let shop = Principal.fromText("uf6dk-hyaaa-aaaaq-qaaaq-cai");

func seqs(alerts : [AlertsAPI.Alert]) : [Nat] = alerts.map(func a = a.seq);

func showNat(n : Nat) : Text = debug_show n;

func registered(state : AlertsAPI.State) : AlertsAPI.Alert = AlertsAPI.record(state, #userRegistered({ user }));

func shopCreated(state : AlertsAPI.State) : AlertsAPI.Alert = AlertsAPI.record(state, #shopCreated({ shop; owner = user }));

suite(
    "Platform alerts",
    func() {
        test(
            "pages newest first, older ones after a page's next",
            func() {
                let state = AlertsAPI.empty();
                for (_ in Nat.range(0, 5)) ignore registered(state);
                let first = AlertsAPI.page(state, staff, null, ?2);
                expect.array<Nat>(seqs(first.items), showNat, func(a, b) = a == b).equal([4, 3]);
                expect.bool(first.next == ?3).isTrue();
                let second = AlertsAPI.page(state, staff, first.next, ?2);
                expect.array<Nat>(seqs(second.items), showNat, func(a, b) = a == b).equal([2, 1]);
                let last = AlertsAPI.page(state, staff, second.next, ?2);
                expect.array<Nat>(seqs(last.items), showNat, func(a, b) = a == b).equal([0]);
                expect.bool(last.next == null).isTrue();
            },
        );

        test(
            "muted types are left out for that staff member only",
            func() {
                let state = AlertsAPI.empty();
                ignore registered(state);
                ignore shopCreated(state);
                ignore registered(state);
                AlertsAPI.setMuted(state, staff, [#userRegistered, #userRegistered]);
                expect.array<Nat>(seqs(AlertsAPI.page(state, staff, null, null).items), showNat, func(a, b) = a == b).equal([1]);
                expect.array<Nat>(seqs(AlertsAPI.page(state, other, null, null).items), showNat, func(a, b) = a == b).equal([2, 1, 0]);
                expect.nat(AlertsAPI.getSettings(state, staff).muted.size()).equal(1);
                AlertsAPI.setMuted(state, staff, []);
                expect.nat(AlertsAPI.page(state, staff, null, null).items.size()).equal(3);
            },
        );

        test(
            "keeps at most MAX_ALERTS, dropping the oldest",
            func() {
                let state = AlertsAPI.empty();
                for (_ in Nat.range(0, AlertsAPI.MAX_ALERTS + 2)) ignore registered(state);
                expect.nat(state.alerts.size()).equal(AlertsAPI.MAX_ALERTS);
                expect.bool(state.alerts.get(Nat.compare, 1) == null).isTrue();
                expect.bool(state.alerts.get(Nat.compare, 2) != null).isTrue();
            },
        );

        test(
            "counts unread unmuted alerts until marked seen",
            func() {
                let state = AlertsAPI.empty();
                let empty = AlertsAPI.summary(state, staff);
                expect.nat(empty.unread).equal(0);
                expect.bool(empty.latest == null).isTrue();
                AlertsAPI.markSeen(state, staff, 5);
                expect.bool(AlertsAPI.getSettings(state, staff).lastSeen == null).isTrue();

                ignore registered(state);
                ignore shopCreated(state);
                ignore registered(state);
                expect.nat(AlertsAPI.summary(state, staff).unread).equal(3);
                AlertsAPI.setMuted(state, staff, [#shopCreated]);
                expect.nat(AlertsAPI.summary(state, staff).unread).equal(2);

                AlertsAPI.markSeen(state, staff, 1);
                let summary = AlertsAPI.summary(state, staff);
                expect.nat(summary.unread).equal(1);
                expect.bool(summary.latest == ?2).isTrue();

                // Never past the newest, never backwards.
                AlertsAPI.markSeen(state, staff, 99);
                expect.bool(AlertsAPI.getSettings(state, staff).lastSeen == ?2).isTrue();
                AlertsAPI.markSeen(state, staff, 0);
                expect.bool(AlertsAPI.getSettings(state, staff).lastSeen == ?2).isTrue();
                expect.nat(AlertsAPI.summary(state, staff).unread).equal(0);
                expect.nat(AlertsAPI.summary(state, other).unread).equal(3);
            },
        );

        test(
            "counts an unread alert behind many muted ones",
            func() {
                let state = AlertsAPI.empty();
                ignore shopCreated(state);
                for (_ in Nat.range(0, 1_500)) ignore registered(state);
                AlertsAPI.setMuted(state, staff, [#userRegistered]);
                expect.nat(AlertsAPI.summary(state, staff).unread).equal(1);
            },
        );

        test(
            "caps the unread count",
            func() {
                let state = AlertsAPI.empty();
                for (_ in Nat.range(0, AlertsAPI.MAX_UNREAD + 10)) ignore registered(state);
                expect.nat(AlertsAPI.summary(state, staff).unread).equal(AlertsAPI.MAX_UNREAD);
            },
        );

        test(
            "typeOf names each kind's tag",
            func() {
                let state = AlertsAPI.empty();
                expect.bool(AlertsAPI.typeOf(registered(state).kind) == #userRegistered).isTrue();
                expect.bool(AlertsAPI.typeOf(shopCreated(state).kind) == #shopCreated).isTrue();
                let registeredShop = AlertsAPI.record(state, #shopRegistered({ shop; owner = user }));
                expect.bool(AlertsAPI.typeOf(registeredShop.kind) == #shopRegistered).isTrue();
                let failed = AlertsAPI.record(state, #shopCreationFailed({ quoteId = 7; owner = user; error = "out of cycles" }));
                expect.bool(AlertsAPI.typeOf(failed.kind) == #shopCreationFailed).isTrue();
            },
        );

        test(
            "clips long error text",
            func() {
                expect.text(AlertsAPI.clip("short")).equal("short");
                let long = Text.join(Array.repeat("x", AlertsAPI.MAX_ERROR_LENGTH + 50).values(), "");
                expect.nat(AlertsAPI.clip(long).size()).equal(AlertsAPI.MAX_ERROR_LENGTH + 1);
            },
        );

        test(
            "pushes only to staff with push on, the type unmuted and Alerts.View still held",
            func() {
                let state = AlertsAPI.empty();
                let formerStaff = Principal.fromText("aaaaa-aa");
                AlertsAPI.setPush(state, staff, true);
                AlertsAPI.setPush(state, formerStaff, true);
                AlertsAPI.setMuted(state, other, []);
                let canReadAlerts = func(p : Principal) : Bool = p != formerStaff;
                let recipients = AlertsAPI.pushRecipients(state, registered(state), canReadAlerts);
                expect.bool(recipients == [staff]).isTrue();
                AlertsAPI.setMuted(state, staff, [#userRegistered]);
                expect.nat(AlertsAPI.pushRecipients(state, registered(state), canReadAlerts).size()).equal(0);
                expect.nat(AlertsAPI.pushRecipients(state, shopCreated(state), canReadAlerts).size()).equal(1);
                AlertsAPI.setPush(state, staff, false);
                expect.nat(AlertsAPI.pushRecipients(state, shopCreated(state), canReadAlerts).size()).equal(0);
            },
        );

        test(
            "push settings keep muted types and read position",
            func() {
                let state = AlertsAPI.empty();
                ignore registered(state);
                AlertsAPI.setMuted(state, staff, [#shopCreated]);
                AlertsAPI.markSeen(state, staff, 0);
                AlertsAPI.setPush(state, staff, true);
                let settings = AlertsAPI.getSettings(state, staff);
                expect.bool(settings.push).isTrue();
                expect.nat(settings.muted.size()).equal(1);
                expect.bool(settings.lastSeen == ?0).isTrue();
                expect.bool(AlertsAPI.getSettings(state, other).push).isFalse();
            },
        );

        test(
            "a queued push is still wanted only with push on, Alerts.View held and its type unmuted",
            func() {
                let state = AlertsAPI.empty();
                let isShopCreated = func(t : AlertsAPI.AlertType) : Bool = t == #shopCreated;
                expect.bool(AlertsAPI.pushWanted(state, staff, true, isShopCreated)).isFalse();
                AlertsAPI.setPush(state, staff, true);
                expect.bool(AlertsAPI.pushWanted(state, staff, true, isShopCreated)).isTrue();
                expect.bool(AlertsAPI.pushWanted(state, staff, false, isShopCreated)).isFalse();
                AlertsAPI.setMuted(state, staff, [#userRegistered]);
                expect.bool(AlertsAPI.pushWanted(state, staff, true, isShopCreated)).isTrue();
                AlertsAPI.setMuted(state, staff, [#shopCreated]);
                expect.bool(AlertsAPI.pushWanted(state, staff, true, isShopCreated)).isFalse();
            },
        );

        test(
            "pushes each alert type at most once per cooldown",
            func() {
                let pushTimes = AlertsAPI.emptyPushTimes();
                let start = 1_000_000_000_000;
                expect.bool(AlertsAPI.takePushTurn(pushTimes, #shopRegistered, start)).isTrue();
                expect.bool(AlertsAPI.takePushTurn(pushTimes, #shopRegistered, start + AlertsAPI.PUSH_COOLDOWN - 1)).isFalse();
                expect.bool(AlertsAPI.takePushTurn(pushTimes, #userRegistered, start + 1)).isTrue();
                expect.bool(AlertsAPI.takePushTurn(pushTimes, #shopRegistered, start + AlertsAPI.PUSH_COOLDOWN)).isTrue();
            },
        );

        test(
            "push text names no principal or error, and each type has its own key",
            func() {
                let error = "trapped at " # user.toText();
                let kinds : [AlertsAPI.AlertKind] = [
                    #userRegistered({ user }),
                    #shopCreated({ shop; owner = user }),
                    #shopRegistered({ shop; owner = user }),
                    #shopCreationFailed({ quoteId = 7; owner = user; error }),
                ];
                for (kind in kinds.values()) {
                    let message = AlertsAPI.pushMessage(kind);
                    for (text in [message.title, message.body].values()) {
                        expect.bool(text.contains(#text(user.toText()))).isFalse();
                        expect.bool(text.contains(#text(shop.toText()))).isFalse();
                        expect.bool(text.contains(#text("trapped"))).isFalse();
                    };
                };
                let keys = AlertsAPI.allTypes.map(AlertsAPI.pushKey);
                for (key in keys.values()) {
                    expect.nat(keys.filter(func(k : Text) : Bool = k == key).size()).equal(1);
                };
            },
        );
    },
);
