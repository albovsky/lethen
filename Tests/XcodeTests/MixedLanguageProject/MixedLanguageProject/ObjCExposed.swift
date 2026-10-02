import Foundation

final class CalledFromObjC: NSObject {
    @objc func calledFromObjC() {}
    @objc func notCalledFromObjC(_: OnlyInExposedSignature) {}
    @objc var readFromObjC: Int { 1 }
    @objc static var staticReadFromObjC: Int { 1 }
    @objc var readByMessage: Int { 1 }
    @objc static var staticReadByMessage: Int { 1 }
    @objc(renamedForObjC) func renamedInSwift() {}
    @objc func namedInSelector() {}
    @objc(renamedSelectorOnly) func renamedSelectorInSwift() {}
    @objc var kvcRead: Int { 1 }
    func notExposed() {}
}

extension CalledFromObjC {
    @objc func calledInExtension() {}
}

extension NSObject {
    @objc func calledOnFrameworkClass() {}
    @objc func notCalledOnFrameworkClass() {}
}

@objc protocol ProtocolAdoptedInObjC {}

@objc enum EnumUsedFromObjC: Int {
    case usedCase
    case unusedCase
}

final class AllocatedFromObjC: NSObject {}

public final class PublicAllocatedFromObjC: NSObject {}

public final class PublicUsedFromSwift {}

@objc(RenamedClassForObjC) final class RenamedClass: NSObject {}

final class NamedInObjCHeader: NSObject {}

final class OnlyInExposedSignature: NSObject {}

final class OnlyForwardDeclared: NSObject {}

final class NotReferencedFromObjC: NSObject {}

final class NamedInObjCString: NSObject {}

@objc(RenamedStringClassForObjC) final class RenamedStringClass: NSObject {}
