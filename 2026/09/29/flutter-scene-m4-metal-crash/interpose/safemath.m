// Loaded with DYLD_INSERT_LIBRARIES into a locally built Flutter app.
//
// SAFEMATH=1  forces MTLCompileOptions to mathMode = .safe (fast math off)
//             for every library the app compiles from source, the way
//             Impeller compiles Flutter GPU shader bundles.
// Always      logs presented frames per second and the mean GPU time per
//             frame (sum of command buffer GPU time / presented drawables).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static BOOL gSafe;
static _Atomic long gLibraries;
static _Atomic long gFrames;
static _Atomic long gGpuMicros;
static _Atomic long gCommits;
static _Atomic long gDone;

static void Swizzle(Class cls, SEL sel, IMP imp, IMP *orig) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return;
  *orig = method_setImplementation(m, imp);
}

static void ForceSafe(MTLCompileOptions *options) {
  if (!gSafe || !options) return;
  if (@available(macOS 15.0, *)) {
    options.mathMode = MTLMathModeSafe;
  } else {
    options.fastMathEnabled = NO;
  }
}

static IMP origSourceSync, origSourceAsync, origNextDrawable, origCommit;

static id NewLibrarySync(id self, SEL _cmd, NSString *src, MTLCompileOptions *opt,
                         NSError **err) {
  MTLCompileOptions *o = opt ? [opt copy] : [MTLCompileOptions new];
  ForceSafe(o);
  atomic_fetch_add(&gLibraries, 1);
  return ((id(*)(id, SEL, NSString *, MTLCompileOptions *, NSError **))origSourceSync)(
      self, _cmd, src, o, err);
}

static void NewLibraryAsync(id self, SEL _cmd, NSString *src, MTLCompileOptions *opt,
                            id handler) {
  MTLCompileOptions *o = opt ? [opt copy] : [MTLCompileOptions new];
  ForceSafe(o);
  atomic_fetch_add(&gLibraries, 1);
  ((void (*)(id, SEL, NSString *, MTLCompileOptions *, id))origSourceAsync)(
      self, _cmd, src, o, handler);
}

static id NextDrawable(id self, SEL _cmd) {
  id d = ((id(*)(id, SEL))origNextDrawable)(self, _cmd);
  if (d) atomic_fetch_add(&gFrames, 1);
  return d;
}

static void Commit(id<MTLCommandBuffer> self, SEL _cmd) {
  atomic_fetch_add(&gCommits, 1);
  [self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
    atomic_fetch_add(&gDone, 1);
    CFTimeInterval t = cb.GPUEndTime - cb.GPUStartTime;
    if (t > 0 && t < 1) atomic_fetch_add(&gGpuMicros, (long)(t * 1e6));
  }];
  ((void (*)(id, SEL))origCommit)(self, _cmd);
}

__attribute__((constructor)) static void Init(void) {
  gSafe = getenv("SAFEMATH") && getenv("SAFEMATH")[0] == '1';
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Class deviceClass = [(NSObject *)device class];
  Swizzle(deviceClass, @selector(newLibraryWithSource:options:error:),
          (IMP)NewLibrarySync, &origSourceSync);
  Swizzle(deviceClass, @selector(newLibraryWithSource:options:completionHandler:),
          (IMP)NewLibraryAsync, &origSourceAsync);
  Swizzle([CAMetalLayer class], @selector(nextDrawable), (IMP)NextDrawable,
          &origNextDrawable);
  id<MTLCommandQueue> queue = [device newCommandQueue];
  Class cbClass = [(NSObject *)[queue commandBuffer] class];
  Swizzle(cbClass, @selector(commit), (IMP)Commit, &origCommit);
  fprintf(stderr, "[safemath] safe=%d device=%s cb=%s\n", gSafe,
          device.name.UTF8String, class_getName(cbClass));
  dispatch_source_t timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                            2 * NSEC_PER_SEC, 0);
  dispatch_source_set_event_handler(timer, ^{
    long f = atomic_exchange(&gFrames, 0);
    long us = atomic_exchange(&gGpuMicros, 0);
    long c = atomic_exchange(&gCommits, 0);
    long d = atomic_exchange(&gDone, 0);
    fprintf(stderr,
            "[safemath] drawables=%.1f/s commits=%.1f/s done=%.1f/s gpu_ms=%.2f/s libraries=%ld\n",
            f / 2.0, c / 2.0, d / 2.0, us / 1000.0 / 2.0, atomic_load(&gLibraries));
  });
  dispatch_resume(timer);
  CFBridgingRetain(timer);
}
