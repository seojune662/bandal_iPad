#import "ReviewStroke.h"
#import <objc/runtime.h>

// Private XCTest classes (stable since Xcode 9; WebDriverAgent uses the same calls).
@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end
@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
@end
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (void)synthesizeEvent:(XCSynthesizedEventRecord *)event completion:(void (^)(BOOL success, NSError *_Nullable error))completion;
@end

@implementation ReviewStroke
+ (nullable NSString *)drawPoints:(NSArray<NSValue *> *)points duration:(NSTimeInterval)duration
                      orientation:(UIInterfaceOrientation)orientation {
    if (points.count < 2) return nil;
    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:points.firstObject.CGPointValue offset:0];
    double step = duration / (double)(points.count - 1);
    for (NSUInteger i = 1; i < points.count; i++) [path moveToPoint:points[i].CGPointValue atOffset:step * i];
    [path liftUpAtOffset:duration + 0.02];
    XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"review stroke" interfaceOrientation:orientation];
    [record addPointerEventPath:path];
    __block BOOL finished = NO;
    __block NSString *failure = nil;
    [[XCTRunnerDaemonSession sharedSession] synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ failure = success ? nil : (error.localizedDescription ?: @"failed"); finished = YES; });
    }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:duration + 10];
    while (!finished && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return finished ? failure : @"timed out";
}
+ (void)skipQuiescenceWaits {
    Class process = NSClassFromString(@"XCUIApplicationProcess");
    Method one = class_getInstanceMethod(process, NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:"));
    if (one) method_setImplementation(one, imp_implementationWithBlock(^(id _, BOOL __) {}));
    Method two = class_getInstanceMethod(process, NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:"));
    if (two) method_setImplementation(two, imp_implementationWithBlock(^(id _, BOOL __, BOOL ___) {}));
}
@end
