import Set "mo:core/Set";

module {
    type OldActor = {};

    type NewActor = {
        folders : Set.Set<Text>;
    };

    /// Folders the media library shows even while they hold no files. Existing vaults start with
    /// none: their files' keys already imply theirs.
    public func migration(_ : OldActor) : NewActor {
        { folders = Set.empty<Text>() };
    };
};
