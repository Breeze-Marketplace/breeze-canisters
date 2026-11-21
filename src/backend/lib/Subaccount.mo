import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import VarArray "mo:core/VarArray";

/// 32-byte ICRC-1 subaccounts derived from IDs.
module {
    public let SIZE = 32;

    /// The principal's length byte, then its bytes, zero-padded: the usual per-user subaccount.
    public func fromPrincipal(principal : Principal) : Blob {
        let bytes = principal.toBlob().toArray();
        let sub = VarArray.repeat<Nat8>(0, SIZE);
        sub[0] := bytes.size().toNat8();
        for (i in bytes.keys()) {
            sub[i + 1] := bytes[i];
        };
        Blob.fromVarArray(sub);
    };

    /// The ID's 4 bytes, most significant first, zero-padded. Shop uses this for per-order payment accounts.
    public func fromNat32(id : Nat32) : Blob {
        let sub = VarArray.repeat<Nat8>(0, SIZE);
        sub[0] := (id >> 24).toNat().toNat8();
        sub[1] := ((id >> 16) & 0xff).toNat().toNat8();
        sub[2] := ((id >> 8) & 0xff).toNat().toNat8();
        sub[3] := (id & 0xff).toNat().toNat8();
        Blob.fromVarArray(sub);
    };
};
