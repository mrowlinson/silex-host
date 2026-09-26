// render.m — host Apple's Silex (macCatalyst, /System/iOSSupport) in-process,
// lay out + render an arbitrary ANF article.json, write a full-article PNG.
// Build: see build.sh. Usage: render <article.json> <out.png> [WIDTHxHEIGHT]
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static id C(NSString *n) { return (id)NSClassFromString(n); }
static id MS(id t, SEL s) { return ((id(*)(id, SEL))objc_msgSend)(t, s); }
static id N(void) { return (id)[NSNull null]; }

static id gBlueprint = nil;
static BOOL gDone = NO;
static id gDOM = nil;

static id Invoke(id target, SEL sel, NSArray *args) {
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target]; [inv setSelector:sel];
    for (NSUInteger i = 0; i < args.count; i++) {
        id a = args[i] == (id)[NSNull null] ? nil : args[i];
        [inv setArgument:&a atIndex:2+i];
    }
    [inv invoke];
    id ret = nil; [inv getReturnValue:&ret]; return ret;
}

@interface Host : NSObject { @public UIView *_view; }
@end
@implementation Host
- (void)addComponentView:(id)v { [_view addSubview:(UIView *)v]; }
- (void)removeComponentView:(id)v { [(UIView *)v removeFromSuperview]; }
@end

static id gPD_Tangier = nil, gPD_CompController = nil, gPD_PresAttrs = nil;
@interface PresDelegate : NSObject
@end
@implementation PresDelegate
- (id)componentController { return gPD_CompController; }
- (id)tangierController { return gPD_Tangier; }
- (id)animationController { return nil; }
- (id)behaviorController { return nil; }
- (id)fullscreenVideoPlaybackManager { return nil; }
- (id)mediaPlaybackController { return nil; }
- (id)presentationAttributes { return gPD_PresAttrs; }
- (id)adDocumentStateManager { return nil; }
- (id)textSelectionManager { return nil; }
- (_Bool)isScrolling { return NO; }
- (id)presentingContentViewController { return nil; }
- (void)updateBehaviorForComponentView:(id)view {}
- (_Bool)addInteractivityFocusForComponent:(id)c { return NO; }
- (_Bool)allowInteractivityFocusForComponent:(id)c { return NO; }
- (void)dismissFullscreenCanvasForComponent:(id)c {}
- (void)removeInteractivityFocusForComponent:(id)c {}
- (id)requestFullScreenCanvasViewControllerForComponent:(id)c canvasController:(id)cc withCompletionBlock:(id)b { return nil; }
- (id)requestFullScreenCanvasViewControllerForComponent:(id)c withCompletionBlock:(id)b { return nil; }
- (void)scrollToRect:(CGRect)r animated:(_Bool)a {}
- (void)willDismissFullscreenCanvasForComponent:(id)c {}
- (void)willReturnToFullscreenForComponent:(id)c {}
- (_Bool)accessibilityShouldHandleInteractionForView:(id)v { return NO; }
@end

@interface DL : NSObject
@end
@implementation DL
- (void)layoutCoordinator:(id)c didIntegrateBlueprint:(id)bp { gBlueprint = bp; gDone = YES; }
- (void)layoutCoordinator:(id)c cancelledLayoutWithOptions:(id)o { gDone = YES; }
@end

// The coordinator builds layout tasks without a DOM; inject ours.
static IMP gOrigCreateDOMOP, gOrigTaskInit4, gOrigTaskInit2;
static id swCreateDOMOP(id self, SEL sel) {
    id p = ((id(*)(id,SEL))gOrigCreateDOMOP)(self, sel);
    if (gDOM) { @try { [p setValue:gDOM forKey:@"DOM"]; } @catch (id e) {} }
    return p;
}
static id swTaskInit4(id self, SEL sel, id o, id i, id b, id d) {
    if (!d && gDOM) d = gDOM;
    return ((id(*)(id,SEL,id,id,id,id))gOrigTaskInit4)(self, sel, o, i, b, d);
}
static id swTaskInit2(id self, SEL sel, id o, id i) {
    id t = ((id(*)(id,SEL,id,id))gOrigTaskInit2)(self, sel, o, i);
    if (gDOM) { @try { [t setValue:gDOM forKey:@"DOM"]; } @catch (id e) {} }
    return t;
}
static void swAuthChallenge(id self, SEL sel, id webView, id challenge, id handler) {
    void (^h)(NSInteger, id) = handler;
    if (h) h(1 /* PerformDefaultHandling */, nil);
}
static void swizzleWebKitAuthChallenges(void) {
    SEL sel = NSSelectorFromString(@"webView:didReceiveAuthenticationChallenge:completionHandler:");
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)n);
    n = objc_getClassList(list, n);
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn || (strncmp(cn, "SX", 2) != 0 && strncmp(cn, "SW", 2) != 0)) continue;
        Method m = class_getInstanceMethod(list[i], sel);
        if (m) method_setImplementation(m, (IMP)swAuthChallenge);
    }
    free(list);
}
static void spin(double secs) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
    while ([[NSDate date] compare:end] == NSOrderedAscending)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: render <article.json> <out.png> [WxH]\n"); return 2; }
        double VW = 390, VH = 844;
        if (argc > 3) { NSString *g = @(argv[3]); NSArray *p = [g componentsSeparatedByString:@"x"]; if (p.count == 2) { VW = [p[0] doubleValue]; VH = [p[1] doubleValue]; } }
        id (*m1)(id, SEL, id) = (void *)objc_msgSend;
        id (*m2)(id, SEL, id, id) = (void *)objc_msgSend;
        id (*m3)(id, SEL, id, id, id) = (void *)objc_msgSend;
        id (*m4)(id, SEL, id, id, id, id) = (void *)objc_msgSend;
        id (*m5)(id, SEL, id, id, id, id, id) = (void *)objc_msgSend;
        id (*m9)(id, SEL, id, id, id, id, id, id, id, id, id) = (void *)objc_msgSend;

        void *h = dlopen("/System/iOSSupport/System/Library/PrivateFrameworks/Silex.framework/Silex", RTLD_LAZY);
        if (!h) { NSLog(@"RESULT status=DLOPEN-FAIL"); return 1; }
        swizzleWebKitAuthChallenges();
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        if (!data) { NSLog(@"RESULT status=READ-FAIL"); return 1; }
        NSError *err = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (!json) { NSLog(@"RESULT status=JSON-FAIL err=%@", err); return 1; }

        id doc = m2([C(@"SXDocument") alloc], NSSelectorFromString(@"initWithJSONObject:andVersion:"), json, @"1.7");
        if (!doc) { NSLog(@"RESULT status=DOC-FAIL"); return 1; }
        NSString *title = [doc valueForKey:@"title"];
        id dc = m2([C(@"SXDocumentController") alloc], NSSelectorFromString(@"initWithDocument:shareURL:"), doc, @"https://example.com/x");
        id dcc = MS([C(@"SXDocumentControllerContainer") alloc], NSSelectorFromString(@"init"));
        m1(dcc, NSSelectorFromString(@"registerDocumentController:"), dc);
        id docProvider = MS([C(@"SXDocumentProvider") alloc], NSSelectorFromString(@"init"));
        [docProvider setValue:doc forKey:@"document"];
        id styleMerger = [dc valueForKey:@"componentStyleMerger"];
        id domFactory = m3([C(@"SXDOMObjectProviderFactory") alloc], NSSelectorFromString(@"initWithDocumentControllerProvider:componentStyleMerger:componentTextStyleMerger:"), dcc, styleMerger, nil);
        id domProvider = MS(domFactory, NSSelectorFromString(@"createDOMObjectProvider"));
        id domFactory2 = m1([C(@"SXDOMFactory") alloc], NSSelectorFromString(@"initWithDocumentProvider:"), docProvider);
        id dom = MS(domFactory2, NSSelectorFromString(@"createDOM"));
        [domProvider setValue:dom forKey:@"DOM"];
        gDOM = dom;
        Method mdom = class_getInstanceMethod((Class)C(@"SXDOMObjectProviderFactory"), NSSelectorFromString(@"createDOMObjectProvider"));
        if (mdom) gOrigCreateDOMOP = method_setImplementation(mdom, (IMP)swCreateDOMOP);
        Method mt4 = class_getInstanceMethod((Class)C(@"SXLayoutTask"), NSSelectorFromString(@"initWithOptions:instructions:blueprint:DOM:"));
        if (mt4) gOrigTaskInit4 = method_setImplementation(mt4, (IMP)swTaskInit4);
        Method mt2 = class_getInstanceMethod((Class)C(@"SXLayoutTask"), NSSelectorFromString(@"initWithOptions:instructions:"));
        if (mt2) gOrigTaskInit2 = method_setImplementation(mt2, (IMP)swTaskInit2);
        NSUInteger ndom = [[[dom valueForKey:@"components"] valueForKey:@"count"] unsignedLongValue];

        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, VW, VH)];
        id viewport = m1([C(@"SXViewport") alloc], NSSelectorFromString(@"initWithView:"), sv);
        id compController = m2([C(@"SXComponentController") alloc], NSSelectorFromString(@"initWithViewport:DOMObjectProvider:"), viewport, domProvider);
        id nn = N();
        id tangierController = Invoke([C(@"SXTangierController") alloc], NSSelectorFromString(@"initWithViewport:scrollView:componentActionHandler:dragItemProvider:componentController:componentInteractionManager:DOMObjectProvider:adIgnorableViewFactory:config:textAttributionProvider:shareHandler:"), @[viewport, sv, nn, nn, compController, nn, domProvider, nn, nn, nn, nn]);

        id sizerEngine = MS([C(@"SXComponentSizerEngine") alloc], NSSelectorFromString(@"init"));
        for (NSString *n in @[@"SXAdvertisementComponentSizerFactory", @"SXArticleLinkComponentSizerFactory", @"SXAudioComponentSizerFactory", @"SXContainerComponentSizerFactory", @"SXDebugComponentSizerFactory", @"SXEmbedVideoComponentSizerFactory", @"SXFlexibleSpacerComponentSizerFactory", @"SXImageComponentSizerFactory", @"SXLineComponentSizerFactory", @"SXMapComponentSizerFactory", @"SXMosaicGalleryComponentSizerFactory", @"SXPlaceholderArticleThumbnailComponentSizerFactory", @"SXQuickLookComponentSizerFactory", @"SXScalableImageComponentSizerFactory", @"SXSectionComponentSizerFactory", @"SXStripGalleryComponentSizerFactory", @"SXSubscriptionButtonComponentSizerFactory", @"SXVideoComponentSizerFactory"]) {
            Class c = NSClassFromString(n);
            if (c) m1(sizerEngine, NSSelectorFromString(@"addFactory:"), MS([c alloc], NSSelectorFromString(@"init")));
        }
        id fontFamProvider = m1([C(@"SXDocumentFontFamilyProvider") alloc], NSSelectorFromString(@"initWithDocument:"), doc);
        id fontIndex = m1([C(@"SXFontIndex") alloc], NSSelectorFromString(@"initWithFontFamilyProviders:"), fontFamProvider ? @[fontFamProvider] : @[]);
        id fontConstructor = m1([C(@"SXFontAttributesConstructor") alloc], NSSelectorFromString(@"initWithFontIndex:"), fontIndex);
        id smartFieldFactory = m2([C(@"SXSmartFieldFactory") alloc], NSSelectorFromString(@"initWithActionProvider:actionSerializer:"), nil, nil);
        id textSourceFactory = m3([C(@"SXTextSourceFactory") alloc], NSSelectorFromString(@"initWithSmartFieldFactory:documentLanguageProvider:fontAttributesConstructor:"), smartFieldFactory, nil, fontConstructor);
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m3([C(@"SXTextComponentSizerFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:textComponentLayoutHosting:textSourceFactory:"), domProvider, tangierController, textSourceFactory));
        id buttonTextProvider = MS([C(@"SXButtonComponentTextProvider") alloc], NSSelectorFromString(@"init"));
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m2([C(@"SXButtonComponentSizerFactory") alloc], NSSelectorFromString(@"initWithTextProvider:textSourceFactory:"), buttonTextProvider, textSourceFactory));
        id recTransFactory = m1([C(@"SXDataRecordValueTransformerFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:"), domProvider);
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m4([C(@"SXDataTableComponentSizerFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:textComponentLayoutHosting:textSourceFactory:recordValueTransformerFactory:"), domProvider, tangierController, nil, recTransFactory));
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m2([C(@"SXEmbedComponentSizerFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:embedDataProvider:"), domProvider, nil));
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m1([C(@"SXIssueCoverComponentSizerFactory") alloc], NSSelectorFromString(@"initWithLayoutAttributesFactory:"), nil));
        m1(sizerEngine, NSSelectorFromString(@"addFactory:"), m2([C(@"SXWebContentComponentSizerFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:loadingPolicyProvider:"), domProvider, nil));

        id unitConvFactory = MS([C(@"SXUnitConverterFactory") alloc], NSSelectorFromString(@"init"));
        id layoutCtxFactory = MS([C(@"SXLayoutContextFactory") alloc], NSSelectorFromString(@"init"));
        id columnCalc = MS([C(@"SXColumnCalculator") alloc], NSSelectorFromString(@"init"));
        id layouterFactory = m3([C(@"SXLayouterFactory") alloc], NSSelectorFromString(@"initWithColumnCalculator:layoutContextFactory:unitConverterFactory:"), columnCalc, layoutCtxFactory, unitConvFactory);
        id compBPFactory = MS([C(@"SXComponentBlueprintFactory") alloc], NSSelectorFromString(@"init"));
        id bpFactory = m2([C(@"SXLayoutBlueprintFactory") alloc], NSSelectorFromString(@"initWithComponentBlueprintFactory:unitConverterFactory:"), compBPFactory, unitConvFactory);
        id opFactory = m5([C(@"SXLayoutOperationFactory") alloc], NSSelectorFromString(@"initWithComponentSizerEngine:layoutBlueprintFactory:layouterFactory:layoutContextFactory:unitConverterFactory:"), sizerEngine, bpFactory, layouterFactory, layoutCtxFactory, unitConvFactory);
        id pipeline = m2([C(@"SXLayoutPipeline") alloc], NSSelectorFromString(@"initWithLayoutOperationFactory:DOMObjectProviderFactory:"), opFactory, domFactory);
        id bpProvider = MS([C(@"SXLayoutBlueprintProvider") alloc], NSSelectorFromString(@"init"));
        id presAttrMgr = MS([C(@"SXPresentationAttributesManager") alloc], NSSelectorFromString(@"init"));
        id presAttrs = MS([C(@"SXPresentationAttributes") alloc], NSSelectorFromString(@"init"));
        [presAttrs setValue:[NSValue valueWithCGSize:CGSizeMake(VW, VH)] forKey:@"canvasSize"];
        [presAttrs setValue:UIContentSizeCategoryLarge forKey:@"contentSizeCategory"];
        [presAttrs setValue:@2.0 forKey:@"contentScaleFactor"];
        m1(presAttrMgr, NSSelectorFromString(@"updateAttributes:"), presAttrs);
        id instrFactory = m1([C(@"SXLayoutInstructionFactory") alloc], NSSelectorFromString(@"initWithPresentationAttributesProvider:"), presAttrMgr);
        id invalMgr = m1([C(@"SXLayoutInvalidationManager") alloc], NSSelectorFromString(@"initWithBlueprintProvider:"), bpProvider);
        id paramsMgr = MS([C(@"SXLayoutParametersManager") alloc], NSSelectorFromString(@"init"));
        id policyMgr = m2([C(@"SXLayoutPolicyManager") alloc], NSSelectorFromString(@"initWithDocumentProvider:hintsConfigurationOptionProvider:"), docProvider, nil);
        id coordinator = m9([C(@"SXLayoutCoordinator") alloc], NSSelectorFromString(@"initWithPipeline:integrator:instructionFactory:invalidationManager:blueprintProvider:DOMObjectProvider:layoutParametersManager:documentProvider:layoutPolicyManager:"), pipeline, compController, instrFactory, invalMgr, bpProvider, domProvider, paramsMgr, docProvider, policyMgr);
        id optFactory = m2([C(@"SXLayoutOptionsFactory") alloc], NSSelectorFromString(@"initWithColumnCalculator:documentProvider:"), columnCalc, docProvider);
        id traits = MS([UITraitCollection class], NSSelectorFromString(@"currentTraitCollection"));
        id (*mkopt)(id, SEL, CGSize, UIEdgeInsets, id, long long, long long, id, BOOL, unsigned long long, double, unsigned long long, long long, long long, id, BOOL, id, id) = (void *)objc_msgSend;
        id opts = mkopt(optFactory, NSSelectorFromString(@"createLayoutOptionsWithViewportSize:safeAreaInsets:traitCollection:bundleSubscriptionStatus:channelSubscriptionStatus:contentSizeCategory:testing:viewingLocation:contentScaleFactor:newsletterSubscriptionStatus:offerUpsellScenario:subscriptionActivationEligibility:offerIdentifier:smartInvertColorsEnabled:conditionKeys:tagSubscriptionStatus:"),
            CGSizeMake(VW, VH), UIEdgeInsetsZero, traits, 0, 0, UIContentSizeCategoryLarge, NO, 0, 2.0, 0, 0, 0, nil, NO, nil, nil);
        DL *dl = [DL new];
        ((void(*)(id, SEL, id))objc_msgSend)(coordinator, NSSelectorFromString(@"setDelegate:"), dl);
        ((void(*)(id, SEL, id))objc_msgSend)(coordinator, NSSelectorFromString(@"layoutWithOptions:"), opts);
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:15];
        while (!gDone && [[NSDate date] compare:end] == NSOrderedAscending)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        if (!gBlueprint) { NSLog(@"RESULT status=LAYOUT-FAIL dom=%lu", (unsigned long)ndom); return 1; }
        CGSize (*mSize)(id, SEL) = (void *)objc_msgSend;
        CGSize bpsz = mSize(gBlueprint, NSSelectorFromString(@"blueprintSize"));
        id cids = MS(gBlueprint, NSSelectorFromString(@"componentIdentifiers"));

        // ---- views ----
        id presDelCont = MS([C(@"SXPresentationDelegateContainer") alloc], NSSelectorFromString(@"init"));
        gPD_Tangier = tangierController; gPD_CompController = compController; gPD_PresAttrs = presAttrs;
        m1(presDelCont, NSSelectorFromString(@"registerPresentationDelegate:"), [PresDelegate new]);
        id styleRFactory = m5([C(@"SXComponentStyleRendererFactory") alloc], NSSelectorFromString(@"initWithImageFillViewFactory:videoFillViewFactory:gradientFactory:repeatableImageFillViewFactory:viewport:"), nil, nil, nil, nil, viewport);
        id imgViewFactory = m2([C(@"SXImageViewFactory") alloc], NSSelectorFromString(@"initWithResourceDataSourceProvider:reachabilityProvider:"), nil, nil);
        id viewEngine = m1([C(@"SXComponentViewEngine") alloc], NSSelectorFromString(@"initWithPostProcessorManager:"), nil);
        SEL addF = NSSelectorFromString(@"addFactory:");
        for (NSString *n in @[@"SXAdvertisementComponentViewFactory", @"SXFlexibleSpacerComponentViewFactory", @"SXLineComponentViewFactory", @"SXSectionComponentViewFactory", @"SXPlaceholderArticleThumbnailComponentViewFactory"]) {
            Class c = NSClassFromString(n);
            if (c) m1(viewEngine, addF, MS([c alloc], NSSelectorFromString(@"init")));
        }
        id nn2 = N(); id tc = tangierController ? tangierController : nn2;
        m1(viewEngine, addF, Invoke([C(@"SXTextComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:tangierController:"), @[domProvider, viewport, presDelCont, styleRFactory, tc]));
        m1(viewEngine, addF, Invoke([C(@"SXImageComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:imageViewFactory:mediaSharingPolicyProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, imgViewFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXContainerComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:mediaSharingPolicyProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXButtonComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:interactionHandlerFactory:interactionHandlerManager:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXVideoComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:sceneStateMonitor:resourceDataSourceProvider:reachabilityProvider:scrollObserverManager:videoPlayerViewControllerManager:bookmarkManager:prerollAdFactory:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, nn2, nn2, nn2, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXAudioComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:resourceDataSourceProvider:host:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXArticleLinkComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:mediaSharingPolicyProvider:interactionHandlerManager:interactionHandlerFactory:URLActionFactory:articleURLFactory:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXDataTableComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:imageViewFactory:componentActionHandler:textComponentLayoutHosting:componentController:adIgnorableViewFactory:config:textAttributionProvider:shareHandler:"), @[domProvider, viewport, presDelCont, styleRFactory, imgViewFactory, nn2, nn2, compController, nn2, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXEmbedVideoComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:sceneStateMonitor:actionHandler:websiteDataStore:proxyAuthenticationHandler:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXIssueCoverComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:viewProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXMapComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:documentTitleProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXMosaicGalleryComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:mediaSharingPolicyProvider:imageViewFactory:canvasControllerFactory:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, imgViewFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXQuickLookComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:fileProvider:quickLookModule:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXScalableImageComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:imageViewFactory:canvasControllerFactory:mediaSharingPolicyProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, imgViewFactory, nn2, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXStripGalleryComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:analyticsReportingProvider:appStateMonitor:mediaSharingPolicyProvider:imageViewFactory:canvasControllerFactory:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, imgViewFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXDebugComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:invalidator:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2]));
        m1(viewEngine, addF, Invoke([C(@"SXEmbedComponentViewFactory") alloc], NSSelectorFromString(@"initWithDOMObjectProvider:viewport:presentationDelegateProvider:componentStyleRendererFactory:reachabilityProvider:embedDataProvider:actionHandler:layoutInvalidator:websiteDataStore:processPoolCache:proxyAuthenticationHandler:sceneStateMonitor:analyticsReportingProvider:"), @[domProvider, viewport, presDelCont, styleRFactory, nn2, nn2, nn2, nn2, nn2, nn2, nn2, nn2, nn2]));
        [compController setValue:viewEngine forKey:@"componentViewEngine"];

        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bpsz.width, bpsz.height > 0 ? bpsz.height : VH)];
        container.backgroundColor = [UIColor whiteColor];
        Host *host = [Host new]; host->_view = container;
        [compController setValue:host forKey:@"host"];
        id colLayout = [opts valueForKey:@"columnLayout"];
        NSUInteger npresented = 0, nfail = 0;
        NSMutableDictionary *viewByCid = [NSMutableDictionary dictionary];
        NSMutableDictionary *cbpByCid = [NSMutableDictionary dictionary];
        for (id cid in [cids allObjects]) {
            id cbp = m1(gBlueprint, NSSelectorFromString(@"componentBlueprintForComponentIdentifier:"), cid);
            @try {
                id v = m3(compController, NSSelectorFromString(@"presentComponentBlueprint:inHost:columnLayout:"), cbp, host, colLayout);
                if (v) {
                    NSValue *fr = [cbp valueForKey:@"frame"];
                    if (fr) [(UIView *)v setFrame:[fr CGRectValue]];
                    [container addSubview:v]; npresented++;
                    viewByCid[cid] = v; cbpByCid[cid] = cbp;
                }
            } @catch (id e) { nfail++; NSLog(@"WARN present %@ failed: %@", cid, e); }
        }
        // nested components: parent map from DOM (object identity), multi-pass present
        NSMapTable *parentOf = [NSMapTable strongToStrongObjectsMapTable];
        NSMapTable *viewByComp = [NSMapTable strongToStrongObjectsMapTable];
        for (id cid in cids) { id v = viewByCid[cid]; if (v) { id cc = [v valueForKey:@"component"]; if (cc) [viewByComp setObject:v forKey:cc]; } }
        NSMutableArray *stack = [[[dom valueForKey:@"components"] valueForKey:@"allComponents"] mutableCopy];
        while (stack.count) {
            id cc = stack.lastObject; [stack removeLastObject];
            id kids = nil; @try { kids = [cc valueForKey:@"components"]; } @catch (id e) {}
            NSArray *ka = nil;
            if ([kids isKindOfClass:[NSArray class]]) ka = kids;
            else if (kids) { @try { ka = [kids valueForKey:@"objects"]; } @catch (id e) {} }
            for (id k in ka) { [parentOf setObject:cc forKey:k]; [stack addObject:k]; }
        }
        id flat = [gBlueprint valueForKey:@"flattenedBlueprint"];
        NSSet *topCids = [NSSet setWithArray:[cids allObjects]];
        if (getenv("SILEX_DEBUG")) {
            NSLog(@"DBG parentOf=%lu flatkeys=%lu", (unsigned long)[[parentOf keyEnumerator] allObjects].count, (unsigned long)[flat count]);
            id domkids = [[dom valueForKey:@"components"] valueForKey:@"allComponents"];
            NSLog(@"DBG domkids=%@ n=%lu", [domkids class], (unsigned long)[domkids count]);
            id c0 = [domkids firstObject];
            NSLog(@"DBG c0=%@ kids=%@", [c0 class], [[c0 valueForKey:@"components"] class]);
            for (id k in flat) { if ([topCids containsObject:k]) continue; id nc = [flat[k] valueForKey:@"component"]; NSLog(@"DBG nested %@ comp=%p pcomp=%p", k, nc, [parentOf objectForKey:nc]); break; }
        }
        for (int pass = 0; pass < 10; pass++) {
            NSUInteger before = npresented;
            for (id k in flat) {
                if (viewByCid[k]) continue;
                id ncbp = flat[k];
                id ncomp = [ncbp valueForKey:@"component"];
                id pcomp = ncomp ? [parentOf objectForKey:ncomp] : nil;
                id pview = pcomp ? [viewByComp objectForKey:pcomp] : nil;
                if (!pview) continue;
                @try {
                    id v = m3(compController, NSSelectorFromString(@"presentComponentBlueprint:inHost:columnLayout:"), ncbp, host, colLayout);
                    if (v) {
                        NSValue *fr = [ncbp valueForKey:@"frame"];
                        if (fr) [(UIView *)v setFrame:[fr CGRectValue]];
                        id pcv = nil; @try { pcv = [pview valueForKey:@"contentView"]; } @catch (id e) {}
                        [(UIView *)(pcv ? pcv : pview) addSubview:v];
                        npresented++;
                        viewByCid[k] = v; cbpByCid[k] = ncbp;
                        if (ncomp) [viewByComp setObject:v forKey:ncomp];
                    }
                } @catch (id e) { nfail++; }
            }
            if (npresented == before) break;
        }
        NSArray *allViews = [viewByCid allValues];
        ((void(*)(id, SEL, id, long long))objc_msgSend)(compController, NSSelectorFromString(@"updateVisibilityStatesForComponentViews:toState:"), allViews, 2);
        for (UIView *svv in allViews) {
            id comp = [svv valueForKey:@"component"];
            if (comp) { @try { m1(svv, NSSelectorFromString(@"loadComponent:"), comp); } @catch (id e) {} }
            if ([svv respondsToSelector:NSSelectorFromString(@"setupTextView")]) { @try { MS(svv, NSSelectorFromString(@"setupTextView")); } @catch (id e) {} }
        }
        // wire sizer textLayouters + textInfos into text views (bypasses finalization processor)
        for (id cid in [viewByCid allKeys]) {
            id cbp = cbpByCid[cid];
            if (!cbp) continue;
            id sizer = [cbp valueForKey:@"componentSizer"];
            id tl = nil;
            @try { tl = [sizer valueForKey:@"textLayouter"]; } @catch (id e) {}
            if (!tl) continue;
            id v = viewByCid[cid];
            if (!v) continue;
            id tv = [v valueForKey:@"textView"];
            if (!tv) continue;
            @try {
                m1(tv, NSSelectorFromString(@"setTextLayouter:"), tl);
                id tinfo = [tl valueForKey:@"textInfo"];
                if (tinfo) [tv setValue:tinfo forKey:@"textInfo"];
                id cv = [v valueForKey:@"contentView"];
                if (cv && ![(UIView *)tv superview]) [(UIView *)cv addSubview:tv];
                NSValue *cfr = [v valueForKey:@"contentFrame"];
                if (cfr) [(UIView *)tv setFrame:[cfr CGRectValue]];
                m1(tangierController, NSSelectorFromString(@"didStartPresentingTextView:"), tv);
            } @catch (id e) { NSLog(@"WARN textwire %@ failed: %@", cid, e); }
        }
        for (UIView *svv in allViews) { MS(svv, NSSelectorFromString(@"renderContentsIfNeeded")); }
        if (getenv("SILEX_DEBUG")) {
            __block void (^dump)(UIView *, int) = ^(UIView *v, int d) {
                NSMutableString *pad = [NSMutableString string];
                for (int i = 0; i < d; i++) [pad appendString:@"  "];
                id comp = nil; @try { comp = [v valueForKey:@"component"]; } @catch (id e) {}
                id tv = nil; @try { tv = [v valueForKey:@"textView"]; } @catch (id e) {}
                id str = nil; @try { str = [[[[tv valueForKey:@"textInfo"] valueForKey:@"storage"] valueForKey:@"string"] substringToIndex:40]; } @catch (id e) {}
                NSLog(@"TREE %@%@ f=%@ comp=%@ str=%@", pad, [v class], NSStringFromCGRect(v.frame), [comp valueForKey:@"role"], str);
                for (UIView *s in v.subviews) dump(s, d+1);
            };
            dump(container, 0);
        }
        [container setNeedsLayout]; [container layoutIfNeeded];
        @try {
            ((void(*)(id, SEL, BOOL))objc_msgSend)(tangierController, NSSelectorFromString(@"setRebuildFlows:"), YES);
            ((void(*)(id, SEL, CGSize, id))objc_msgSend)(tangierController, NSSelectorFromString(@"updateCanvasSize:forComponentViews:"), CGSizeMake(bpsz.width, bpsz.height), allViews);
        } @catch (id e) { NSLog(@"WARN canvas failed: %@", e); }
        spin(4);

        CGFloat scale = 2.0;
        size_t W = (size_t)(container.bounds.size.width * scale), H = (size_t)(container.bounds.size.height * scale);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);
        CGContextTranslateCTM(ctx, 0, H);
        CGContextScaleCTM(ctx, scale, -scale);
        [container.layer renderInContext:ctx];
        CGImageRef im = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        NSURL *u = [NSURL fileURLWithPath:@(argv[2])];
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)u, (__bridge CFStringRef)@"public.png", 1, NULL);
        CGImageDestinationAddImage(dst, im, NULL);
        BOOL ok = CGImageDestinationFinalize(dst);
        CFRelease(dst); CGImageRelease(im);
        NSLog(@"RESULT status=%@ dom=%lu presented=%lu pfail=%lu bpsize=%.0fx%.0f title=%@", ok ? @"OK" : @"PNG-FAIL",
            (unsigned long)ndom, (unsigned long)npresented, (unsigned long)nfail, bpsz.width, bpsz.height, title ?: @"?");
        return ok ? 0 : 1;
    }
}
