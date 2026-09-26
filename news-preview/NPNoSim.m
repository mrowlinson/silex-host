#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void noSetup(id self, SEL _cmd) {
  NSLog(@"[NPNoSim] suppressed NPSimulatedDeviceManager -setup");
}

__attribute__((constructor)) static void initNoSim(void) {
  Class c = objc_getClass("NPSimulatedDeviceManager");
  if (!c) {
    NSLog(@"[NPNoSim] class NOT FOUND");
    return;
  }
  Method m = class_getInstanceMethod(c, @selector(setup));
  if (!m) {
    NSLog(@"[NPNoSim] setup method NOT FOUND");
    return;
  }
  method_setImplementation(m, (IMP)noSetup);
  NSLog(@"[NPNoSim] patched setup -> no-op");
}
