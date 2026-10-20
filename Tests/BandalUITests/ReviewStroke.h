#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Draws one continuous touch path. XCUICoordinate can only drag in a straight
/// line, so the review recording uses XCTest's event synthesizer for curves.
@interface ReviewStroke : NSObject
/// Blocks (spinning the current run loop) until the gesture has been delivered.
+ (nullable NSString *)drawPoints:(NSArray<NSValue *> *)points
                         duration:(NSTimeInterval)duration
                      orientation:(UIInterfaceOrientation)orientation;
/// Recording only: XCTest waits up to 60 s for the app to idle before every action,
/// and an open web page never idles. The test paces itself with explicit pauses instead.
+ (void)skipQuiescenceWaits;
@end

NS_ASSUME_NONNULL_END
