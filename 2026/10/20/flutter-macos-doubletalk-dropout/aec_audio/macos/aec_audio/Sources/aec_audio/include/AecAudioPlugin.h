#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif
@interface AecAudioPlugin : NSObject<FlutterPlugin>
@end
