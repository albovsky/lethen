@import Foundation;
@import MixedFramework; // periphery:ignore

#if MIXED_NEVER_DEFINED
@import MixedFramework.MFComparison;
#endif

NSString *importsIgnored(void) {
    return @"ignored";
}
