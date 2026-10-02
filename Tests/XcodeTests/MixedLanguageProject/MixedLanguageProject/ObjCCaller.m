#import "ObjCCaller.h"
#import "MixedLanguageProject-Swift.h"

@interface ObjCAdopter : NSObject <ProtocolAdoptedInObjC>
@end

@implementation ObjCAdopter
@end

@implementation ObjCCaller

- (void)run {
    CalledFromObjC *object = [[CalledFromObjC alloc] init];
    [object calledFromObjC];
    [object renamedForObjC];
    [object calledInExtension];
    [object calledOnFrameworkClass];
    NSInteger value = object.readFromObjC + CalledFromObjC.staticReadFromObjC;
    (void)value;
    (void)[object readByMessage];
    (void)[CalledFromObjC staticReadByMessage];
    (void)[[AllocatedFromObjC alloc] init];
    (void)[[RenamedClassForObjC alloc] init];
    (void)[[PublicAllocatedFromObjC alloc] init];
    EnumUsedFromObjC enumValue = EnumUsedFromObjCUsedCase;
    (void)enumValue;
    // Names that clang's index cannot show as references: only their spelling in the source says so.
    SEL selector = @selector(namedInSelector);
    (void)selector;
    (void)NSClassFromString(@"NamedInObjCString");
    (void)[object valueForKey:@"kvcRead"];
    (void)NSSelectorFromString(@"renamedSelectorOnly");
    (void)NSClassFromString(@"RenamedStringClassForObjC");
    (void)NSSelectorFromString(@"setWrittenBySetterSelector:");
    (void)NSSelectorFromString(@"initWithObjCName:");
}

@end
