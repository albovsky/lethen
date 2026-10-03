@import Foundation;
@import MixedFramework.MFComparison;
@import MixedFramework.MFLogging;

BOOL importsUsedFunction(id a, id b) {
    return MFIsEqual(a, b);
}
