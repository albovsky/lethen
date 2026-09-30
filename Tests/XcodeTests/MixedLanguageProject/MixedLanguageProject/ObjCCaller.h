#import <Foundation/Foundation.h>

@class NamedInObjCHeader;
@class OnlyForwardDeclared;

void takeNamedInObjCHeader(NamedInObjCHeader *value);

@interface ObjCCaller : NSObject
- (void)run;
@end
