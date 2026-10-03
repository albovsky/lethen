/// Compiled into both the scanned tool and `UnscannedTool`. Only the unscanned one names `SharedWidget`.
struct SharedWidget {
    let entry: SharedEntry

    init() {
        entry = SharedEntry()
    }
}

/// Used only by `SharedWidget`.
struct SharedEntry {}

/// Named by neither target.
struct SharedUnused {}

/// `UnscannedTool` declares and uses its own `SharedPrivate`; this one is out of its other files' reach.
private struct SharedPrivate {}
