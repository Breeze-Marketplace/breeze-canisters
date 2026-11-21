import Nat "mo:base/Nat";

module {
    public type CanisterSettings = {
        controllers : ?[Principal];
        compute_allocation : ?Nat;
        memory_allocation : ?Nat;
        freezing_threshold : ?Nat;
    };

    public type DefiniteCanisterSettings = {
        controllers : [Principal];
        compute_allocation : Nat;
        memory_allocation : Nat;
        freezing_threshold : Nat;
    };

    type HttpHeader = {
        name : Text;
        value : Text;
    };

    public type HttpRequestResult = {
        status : Nat;
        headers : [HttpHeader];
        body : Blob;
    };

    /// The management canister calls a transform with one record argument.
    public type TransformArgs = { response : HttpRequestResult; context : Blob };
    public type TransformFunction = shared query TransformArgs -> async HttpRequestResult;

    public type HttpRequestArgs = {
        url : Text;
        max_response_bytes : ?Nat64;
        method : { #get; #head; #post };
        headers : [HttpHeader];
        body : ?Blob;
        transform : ?{
            function : TransformFunction;
            context : Blob;
        };
        is_replicated : ?Bool;
    };

    /// A canister snapshot, as `take_canister_snapshot` and `list_canister_snapshots` return it.
    public type Snapshot = {
        id : Blob;
        taken_at_timestamp : Nat64;
        total_size : Nat64;
    };

    public type Management = actor {
        deposit_cycles : ({ canister_id : Principal }) -> async ();
        create_canister : ({
            settings : ?CanisterSettings;
        }) -> async ({ canister_id : Principal });
        update_settings : ({
            canister_id : Principal;
            settings : CanisterSettings;
            sender_canister_version : ?Nat64;
        }) -> ();
        install_code : ({
            mode : {
                #install;
                #reinstall;
                #upgrade : ?{
                    skip_pre_upgrade : ?Bool;
                    wasm_memory_persistence : ?{ #keep; #replace };
                };
            };
            canister_id : Principal;
            wasm_module : Blob;
            arg : Blob;
        }) -> async ();
        upload_chunk : ({ chunk : Blob; canister_id : Principal }) -> async ({
            hash : Blob;
        });
        clear_chunk_store : ({ canister_id : Principal }) -> async ();
        install_chunked_code : ({
            mode : {
                #install;
                #reinstall;
                #upgrade : ?{
                    skip_pre_upgrade : ?Bool;
                    wasm_memory_persistence : ?{ #keep; #replace };
                };
            };
            target_canister : Principal;
            store_canister : ?Principal;
            chunk_hashes_list : [Blob];
            wasm_module_hash : Blob;
            arg : Blob;
            sender_canister_version : ?Nat64;
        }) -> async ();
        uninstall_code : ({ canister_id : Principal }) -> async ();
        start_canister : ({ canister_id : Principal }) -> async ();
        stop_canister : ({ canister_id : Principal }) -> async ();
        take_canister_snapshot : ({
            canister_id : Principal;
            replace_snapshot : ?Blob;
        }) -> async Snapshot;
        list_canister_snapshots : ({ canister_id : Principal }) -> async [Snapshot];
        load_canister_snapshot : ({
            canister_id : Principal;
            snapshot_id : Blob;
            sender_canister_version : ?Nat64;
        }) -> async ();
        canister_status : ({ canister_id : Principal }) -> async ({
            status : { #running; #stopping; #stopped };
            settings : DefiniteCanisterSettings;
            module_hash : ?Blob;
            memory_size : ?Nat;
            cycles : ?Nat;
        });
        http_request : (HttpRequestArgs) -> async (HttpRequestResult);
        ecdsa_public_key : ({
            canister_id : ?Principal;
            derivation_path : [Blob];
            key_id : {
                curve : { #secp256k1 };
                name : Text;
            };
        }) -> async ({ public_key : Blob; chain_code : Blob });
        sign_with_ecdsa : ({
            message_hash : Blob;
            derivation_path : [Blob];
            key_id : {
                curve : { #secp256k1 };
                name : Text;
            };
        }) -> async ({ signature : Blob });
    };

    public func getManagementCanister() : Management {
        let ic = actor "aaaaa-aa" : Management;

        return ic;
    };
};
