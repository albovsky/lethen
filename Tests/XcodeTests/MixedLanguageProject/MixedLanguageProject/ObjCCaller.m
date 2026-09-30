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
}

@end
