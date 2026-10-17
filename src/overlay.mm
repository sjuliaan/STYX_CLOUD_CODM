#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "overlay.h"
#include "config.h"
#include "esp.h"
#include "menu.h"
#include "styxlog.h"

#include "imgui.h"
#include "imgui_impl_metal.h"

// ---------------------------------------------------------------------------
// Self-contained Metal + ImGui overlay (same architecture as the reference mod:
// own MTLCommandQueue, own MTKView draw loop, own windows — never touches
// Unity's renderer).
//
// Two windows:
//   overlay window : full screen, hosts the MTKView, renders ESP + menu.
//                    userInteractionEnabled toggled (menu open = interactive).
//   icon window    : tiny, transparent, sits over the floating icon and turns
//                    taps/drags into menu gestures. Interactive while closed.
// Because a window with userInteractionEnabled == NO is skipped entirely by
// UIApplication, this gives reliable pass-through to the game.
// ---------------------------------------------------------------------------

static UIWindow  *g_overlayWin = nil;
static UIWindow  *g_iconWin    = nil;
static MTKView   *g_mtkView    = nil;
static id<MTLCommandQueue> g_queue = nil;
static bool       g_prevVisible = false;
static int        g_drawFrames  = 0;

static UIWindow *styx_key_window(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.keyWindow;
}

#pragma mark - Renderer

@interface StyxRenderer : NSObject <MTKViewDelegate>
@end

@implementation StyxRenderer

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
        if (rpd == nil) return;

        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        if (cb == nil) return;

        ImGuiIO &io = ImGui::GetIO();
        CGSize sz = view.bounds.size;
        io.DisplaySize = ImVec2((float)sz.width, (float)sz.height);
        CGFloat sc = view.contentScaleFactor;
        if (sc < 1.0) sc = 1.0;
        io.DisplayFramebufferScale = ImVec2((float)sc, (float)sc);

        styx_menu_set_view_size((float)sz.width, (float)sz.height);

        ImGui_ImplMetal_NewFrame(rpd);
        ImGui::NewFrame();

        styx_esp_collect((float)sz.width, (float)sz.height);
        styx_menu_draw();
        styx_esp_draw();

        ImGui::Render();

        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
        [enc endEncoding];

        [cb presentDrawable:view.currentDrawable];
        [cb commit];

        // Window-interaction bookkeeping on the menu open/close transition.
        bool vis = styx_menu_visible();
        if (vis != g_prevVisible) {
            g_prevVisible = vis;
            g_overlayWin.userInteractionEnabled = vis;
            if (vis) {
                g_iconWin.hidden = YES;
            } else {
                float ix = 0, iy = 0;
                styx_menu_icon_origin(&ix, &iy);
                g_iconWin.frame = CGRectMake(ix, iy, styx_menu_icon_size(), styx_menu_icon_size());
                g_iconWin.hidden = NO;
            }
            styx_log("[overlay] menu %s", vis ? "OPEN" : "closed");
        }

        if (g_drawFrames < 3) {
            styx_log("[overlay] frame %d rendered (%.0fx%.0f pt, scale %.2f)", g_drawFrames,
                     sz.width, sz.height, sc);
            g_drawFrames++;
        }
    }
}

@end

static StyxRenderer *g_renderer = nil;

#pragma mark - Touches for the ImGui panel

@interface StyxOverlayView : UIView
@end

@implementation StyxOverlayView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)p.x, (float)p.y);
    io.AddMouseButtonEvent(0, true);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    ImGui::GetIO().AddMousePosEvent((float)p.x, (float)p.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)p.x, (float)p.y);
    io.AddMouseButtonEvent(0, false);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

@end

#pragma mark - Floating icon window

@interface StyxIconView : UIView
@end

@implementation StyxIconView

// Convert any touch to screen coordinates (independent of the icon window
// moving under the finger), then feed the menu gesture logic.
static CGPoint styx_screen_point(UITouch *t, UIWindow *w) {
    CGPoint inWin = [t locationInView:w];
    return [w convertPoint:inWin toWindow:nil];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint s = styx_screen_point(touches.anyObject, self.window);
    styx_menu_touch_begin((float)s.x, (float)s.y);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint s = styx_screen_point(touches.anyObject, self.window);
    styx_menu_touch_move((float)s.x, (float)s.y);
    if (!styx_menu_visible()) {
        float ix = 0, iy = 0;
        styx_menu_icon_origin(&ix, &iy);
        self.window.frame = CGRectMake(ix, iy, styx_menu_icon_size(), styx_menu_icon_size());
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint s = styx_screen_point(touches.anyObject, self.window);
    styx_menu_touch_end((float)s.x, (float)s.y);
    if (styx_menu_visible()) {
        // Opening the panel: the overlay window takes over interaction.
        g_overlayWin.userInteractionEnabled = YES;
        self.window.hidden = YES;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint s = styx_screen_point(touches.anyObject, self.window);
    styx_menu_touch_end((float)s.x, (float)s.y);
}

@end

#pragma mark - Bootstrap

@interface StyxOverlayVC : UIViewController
@end

@implementation StyxOverlayVC
- (void)loadView {
    StyxOverlayView *v = [[StyxOverlayView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = v;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface StyxIconVC : UIViewController
@end

@implementation StyxIconVC
- (void)loadView {
    StyxIconView *v = [[StyxIconView alloc] initWithFrame:CGRectMake(0, 0, styx_menu_icon_size(), styx_menu_icon_size())];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static int g_startRetries = 0;

static void styx_overlay_build(void) {
    UIWindow *key = styx_key_window();
    if (!key) {
        if (g_startRetries++ < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ styx_overlay_build(); });
        } else {
            styx_log("[overlay] gave up waiting for a key window");
        }
        return;
    }

    @try {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { styx_log("[overlay] MTLCreateSystemDefaultDevice failed"); return; }

        g_queue = [dev newCommandQueue];
        if (!g_queue) { styx_log("[overlay] newCommandQueue failed"); return; }

        CGRect bounds = UIScreen.mainScreen.bounds;

        StyxOverlayVC *vc = [[StyxOverlayVC alloc] init];
        g_overlayWin = [[UIWindow alloc] initWithFrame:bounds];
        if ([g_overlayWin respondsToSelector:@selector(setWindowScene:)] && key.windowScene)
            g_overlayWin.windowScene = key.windowScene;
        g_overlayWin.rootViewController = vc;
        g_overlayWin.backgroundColor = [UIColor clearColor];
        g_overlayWin.opaque = NO;
        g_overlayWin.windowLevel = UIWindowLevelNormal + 100;
        g_overlayWin.userInteractionEnabled = NO;   // pass-through until menu opens

        g_mtkView = [[MTKView alloc] initWithFrame:vc.view.bounds device:dev];
        g_mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        g_mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        g_mtkView.opaque = NO;
        g_mtkView.backgroundColor = [UIColor clearColor];
        g_mtkView.layer.opaque = NO;
        g_mtkView.framebufferOnly = YES;
        g_mtkView.enableSetNeedsDisplay = NO;
        g_mtkView.paused = NO;
        g_mtkView.preferredFramesPerSecond = 60;
        g_mtkView.userInteractionEnabled = NO;
        g_mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        g_renderer = [[StyxRenderer alloc] init];

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = NULL;
        io.LogFilename = NULL;
        io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
        io.FontGlobalScale = 1.5f;
        ImGui_ImplMetal_Init(dev);
        styx_menu_apply_style();

        // Attach the delegate only after the ImGui context exists, so a draw
        // callback can never run against an uninitialised context.
        g_mtkView.delegate = g_renderer;
        [vc.view addSubview:g_mtkView];

        // Icon window.
        StyxIconVC *ivc = [[StyxIconVC alloc] init];
        float ix = 0, iy = 0;
        styx_menu_icon_origin(&ix, &iy);
        float isz = styx_menu_icon_size();
        g_iconWin = [[UIWindow alloc] initWithFrame:CGRectMake(ix, iy, isz, isz)];
        if ([g_iconWin respondsToSelector:@selector(setWindowScene:)] && key.windowScene)
            g_iconWin.windowScene = key.windowScene;
        g_iconWin.rootViewController = ivc;
        g_iconWin.backgroundColor = [UIColor clearColor];
        g_iconWin.opaque = NO;
        g_iconWin.windowLevel = UIWindowLevelNormal + 200;

        g_overlayWin.hidden = NO;
        g_iconWin.hidden = NO;

        styx_log("[overlay] ready: device=%s queue ok, windows up", [[dev name] UTF8String]);
    } @catch (NSException *e) {
        styx_log("[overlay] EXCEPTION: %s", [[e reason] UTF8String]);
    }
}

void styx_overlay_start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ styx_overlay_build(); });
}
