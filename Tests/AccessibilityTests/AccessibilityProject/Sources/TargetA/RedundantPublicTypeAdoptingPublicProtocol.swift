import Foundation

public protocol RedundantPublicTypeAdoptingPublicProtocol_Protocol {
    var scheme: Int { get }
    func queryItems() -> Int
}

// Public, but only used within this module, so the type itself is redundantly public. Its witnesses of the public
// protocol requirements must remain public.
public struct RedundantPublicTypeAdoptingPublicProtocol: RedundantPublicTypeAdoptingPublicProtocol_Protocol {
    public var scheme: Int { 1 }
    public func queryItems() -> Int { 2 }
    public var extra: Int { 3 }
}

func redundantPublicTypeAdoptingPublicProtocolUser() -> Int {
    let value = RedundantPublicTypeAdoptingPublicProtocol()
    return value.scheme + value.queryItems() + value.extra
}

// Control: an internal type's public witnesses are redundant.
struct InternalTypeAdoptingPublicProtocol: RedundantPublicTypeAdoptingPublicProtocol_Protocol {
    public var scheme: Int { 1 }
    func queryItems() -> Int { 2 }
}

public class InternalTypeAdoptingPublicProtocolRetainer {
    public init() {
        let value = InternalTypeAdoptingPublicProtocol()
        _ = value.scheme + value.queryItems()
        _ = redundantPublicTypeAdoptingPublicProtocolUser()
    }
}
