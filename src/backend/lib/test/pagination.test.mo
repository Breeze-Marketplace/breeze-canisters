import { expect } "mo:test";
import { suite; test } "mo:test";
import Nat "mo:core/Nat";

import Pagination "../Pagination";

func id(n : Nat) : Nat = n;

func page(items : [Nat], after : ?Nat, limit : ?Nat) : Pagination.Page<Nat, Nat> {
    Pagination.page(items, id, Nat.compare, after, limit);
};

suite(
    "Pagination.page",
    func() {
        test(
            "walks every item once, in order",
            func() {
                let items = [5, 3, 9, 1, 7];
                let p1 = page(items, null, ?2);
                expect.array(p1.items, Nat.toText, Nat.equal).equal([1, 3]);
                expect.option(p1.next, Nat.toText, Nat.equal).equal(?3);
                let p2 = page(items, p1.next, ?2);
                expect.array(p2.items, Nat.toText, Nat.equal).equal([5, 7]);
                let p3 = page(items, p2.next, ?2);
                expect.array(p3.items, Nat.toText, Nat.equal).equal([9]);
                expect.option(p3.next, Nat.toText, Nat.equal).isNull();
            },
        );
        test(
            "has no next cursor when the last page is exactly full",
            func() {
                let p = page([1, 2], null, ?2);
                expect.array(p.items, Nat.toText, Nat.equal).equal([1, 2]);
                expect.option(p.next, Nat.toText, Nat.equal).isNull();
            },
        );
        test(
            "resumes after a cursor whose item was removed",
            func() {
                let p = page([1, 2, 4, 5], ?3, ?10);
                expect.array(p.items, Nat.toText, Nat.equal).equal([4, 5]);
            },
        );
        test(
            "pages in descending order",
            func() {
                let p = Pagination.page([1, 2, 3], id, Pagination.descending(Nat.compare), ?3, ?10);
                expect.array(p.items, Nat.toText, Nat.equal).equal([2, 1]);
            },
        );
        test(
            "clamps the limit",
            func() {
                expect.nat(Pagination.clampLimit(null)).equal(Pagination.DEFAULT_LIMIT);
                expect.nat(Pagination.clampLimit(?0)).equal(1);
                expect.nat(Pagination.clampLimit(?1_000_000)).equal(Pagination.MAX_LIMIT);
            },
        );
    },
);
