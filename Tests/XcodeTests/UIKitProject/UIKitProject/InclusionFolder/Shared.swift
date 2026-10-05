/// In a synchronized folder that only the `Target With Spaces` target owns, which the app's exception set for the
/// folder lists, so the app compiles it too.
enum SharedFromAnotherTargetsFolder {
    static func used() {}

    static func unused() {}
}
