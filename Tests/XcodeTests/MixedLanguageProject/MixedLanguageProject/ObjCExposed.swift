import Foundation

final class CalledFromObjC: NSObject {
    @objc func calledFromObjC() {}
    @objc func notCalledFromObjC(_: OnlyInExposedSignature) {}
    @objc var readFromObjC: Int { 1 }
    @objc static var staticReadFromObjC: Int { 1 }
    @objc(renamedForObjC) func renamedInSwift() {}
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

@objc(RenamedClassForObjC) final class RenamedClass: NSObject {}

final class NamedInObjCHeader: NSObject {}

final class OnlyInExposedSignature: NSObject {}

final class OnlyForwardDeclared: NSObject {}

final class NotReferencedFromObjC: NSObject {}
