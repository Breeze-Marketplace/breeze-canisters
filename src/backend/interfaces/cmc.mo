import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import VarArray "mo:core/VarArray";

/// The NNS cycles minting canister (CMC): the part a canister uses to turn ICP into cycles for
/// itself or another canister. Same ID on mainnet and the local network.
module {
    public let CANISTER_ID = "rkp4c-7iaaa-aaaaa-aaaca-cai";

    /// `TPUP` (0x50555054) as the 8-byte little-endian ICRC-1 memo the CMC's `notify_top_up` reads.
    /// A transfer with any other memo is refunded.
    public let TOP_UP_MEMO : Blob = "\54\50\55\50\00\00\00\00";

    public type NotifyError = {
        /// The CMC sent the ICP back, minus a fee.
        #Refunded : { reason : Text; block_index : ?Nat64 };
        /// Another notification for this block is being processed: ask again later.
        #Processing;
        /// The block is older than the CMC accepts; the argument is the oldest block it does.
        #TransactionTooOld : Nat64;
        #InvalidTransaction : Text;
        #Other : { error_code : Nat64; error_message : Text };
    };

    public type NotifyTopUpResult = { #Ok : Nat; #Err : NotifyError };

    public type Cmc = actor {
        notify_top_up : ({ block_index : Nat64; canister_id : Principal }) -> async NotifyTopUpResult;
    };

    public func cmc() : Cmc = actor (CANISTER_ID);

    /// The CMC subaccount for topping up `canisterId`: its principal's length, then its bytes,
    /// zero-padded to 32. ICP sent there (with `TOP_UP_MEMO`) becomes `canisterId`'s cycles once
    /// someone calls `notify_top_up` with the block.
    public func topUpSubaccount(canisterId : Principal) : Blob {
        let bytes = canisterId.toBlob().toArray();
        let subaccount = VarArray.repeat<Nat8>(0, 32);
        subaccount[0] := Nat8.fromNat(bytes.size());
        for (index in bytes.keys()) subaccount[index + 1] := bytes[index];
        Blob.fromVarArray(subaccount);
    };
};
