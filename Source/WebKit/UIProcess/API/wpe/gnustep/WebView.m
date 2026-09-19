#import "WebView.h"
#import "GSWebRunLoop.h"

#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <xkbcommon/xkbcommon-keysyms.h>

NSString * const WebViewProgressStartedNotification  = @"WebViewProgressStartedNotification";
NSString * const WebViewProgressFinishedNotification = @"WebViewProgressFinishedNotification";

typedef struct GSWebViewImpl {
    WPEDisplay      *display;
    WebKitWebView   *webView;
    WPEView         *wpeView;
    NSBitmapImageRep *rep;      /* current frame, RGBA premultiplied */
    WebView         *owner;     /* unretained back-pointer */
    id               frameLoadDelegate;  /* unretained, per AppKit convention */
} GSWebViewImpl;

#define IMPL ((GSWebViewImpl *)_impl)

/* ---- SHM buffer -> NSBitmapImageRep ------------------------------------
 * WPE hands us premultiplied ARGB8888 little-endian, i.e. B,G,R,A in memory.
 * NSBitmapImageRep wants R,G,B,A, so swap the red and blue channels.
 * Stride may exceed width*4, so copy row by row.
 */
static NSBitmapImageRep *repFromSHM(WPEBufferSHM *shm, int w, int h)
{
    GBytes *bytes = wpe_buffer_shm_get_data(shm);
    if (!bytes)
        return nil;
    gsize srcLen = 0;
    const unsigned char *src = (const unsigned char *)g_bytes_get_data(bytes, &srcLen);
    guint stride = wpe_buffer_shm_get_stride(shm);
    if (!src || (gsize)stride * h > srcLen)
        return nil;

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:w
                      pixelsHigh:h
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:w * 4
                    bitsPerPixel:32];
    if (!rep)
        return nil;

    unsigned char *dst = [rep bitmapData];
    for (int y = 0; y < h; y++) {
        const unsigned char *s = src + (size_t)y * stride;
        unsigned char *d = dst + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            d[0] = s[2];  /* R <- R (BGRA byte 2) */
            d[1] = s[1];  /* G */
            d[2] = s[0];  /* B <- B (BGRA byte 0) */
            d[3] = s[3];  /* A */
            s += 4; d += 4;
        }
    }
    return rep;
}

/* ---- Cookie storage ----------------------------------------------------
 * WebKit keeps cookies only in memory unless told where to store them, so
 * every launch would look like a new browser to websites. Persist them per
 * application at <user Library>/WebKit/<bundle id or process name>/, mirroring
 * Apple's ~/Library/WebKit/<bundle id>/. The Library directory comes from the
 * active GNUstep filesystem layout rather than a hardcoded path.
 */
static void setUpPersistentCookieStorage(void)
{
    static BOOL done = NO;
    if (done)
        return;
    done = YES;

    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (![dirs count])
        return;
    NSString *app = [[NSBundle mainBundle] bundleIdentifier];
    if (![app length])
        app = [[NSProcessInfo processInfo] processName];
    NSString *dir = [[[dirs objectAtIndex:0] stringByAppendingPathComponent:@"WebKit"]
                                             stringByAppendingPathComponent:app];

    /* Cookies hold login sessions, so keep the directory private. */
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0700]
                                                      forKey:NSFilePosixPermissions];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:attrs
                                                         error:&error]) {
        NSLog(@"WebView: cannot create cookie directory %@: %@", dir, error);
        return;
    }

    WebKitCookieManager *cookies = webkit_network_session_get_cookie_manager(webkit_network_session_get_default());
    webkit_cookie_manager_set_persistent_storage(cookies,
        [[dir stringByAppendingPathComponent:@"Cookies.sqlite"] fileSystemRepresentation],
        WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
}

/* Private methods, declared so the C callbacks below can reference them. */
@interface WebView (GSPrivate)
- (void)_bufferRendered:(void *)bufferPtr;
- (void)_loadChanged:(int)event;
- (void)_loadFailed:(const char *)uri message:(const char *)msg;
- (void)_titleChanged;
- (void)_progressChanged;
@end

/* ---- GObject callbacks ------------------------------------------------- */

static void onBufferRendered(WPEView *view, WPEBuffer *buffer, gpointer data)
{
    (void)view;
    [(WebView *)data _bufferRendered:buffer];
}

static void onLoadChanged(WebKitWebView *v, WebKitLoadEvent e, gpointer data)
{
    (void)v;
    [(WebView *)data _loadChanged:(int)e];
}

static void onLoadFailed(WebKitWebView *v, WebKitLoadEvent e, const char *uri,
                         GError *err, gpointer data)
{
    (void)v; (void)e;
    [(WebView *)data _loadFailed:uri message:(err ? err->message : "unknown error")];
}

static void onTitleChanged(GObject *o, GParamSpec *p, gpointer data)
{
    (void)o; (void)p;
    [(WebView *)data _titleChanged];
}

static void onProgressChanged(GObject *o, GParamSpec *p, gpointer data)
{
    (void)o; (void)p;
    [(WebView *)data _progressChanged];
}

@implementation WebView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (!self)
        return nil;

    [GSWebRunLoop start];
    setUpPersistentCookieStorage();

    _impl = calloc(1, sizeof(GSWebViewImpl));
    IMPL->owner = self;

    IMPL->display = wpe_display_headless_new();
    if (!IMPL->display) {
        NSLog(@"WebView: failed to create WPE headless display");
        return self;
    }
    /* The headless display reports no input devices, so pages would see
     * (pointer: none) and (hover: none). This view is driven by AppKit's
     * mouse and keyboard. */
    wpe_display_set_available_input_devices(IMPL->display,
        (WPEAvailableInputDevices)(WPE_AVAILABLE_INPUT_DEVICE_MOUSE | WPE_AVAILABLE_INPUT_DEVICE_KEYBOARD));

    IMPL->webView = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                                "display", IMPL->display, NULL));
    IMPL->wpeView = webkit_web_view_get_wpe_view(IMPL->webView);
    if (!IMPL->wpeView) {
        NSLog(@"WebView: failed to obtain WPEView");
        return self;
    }

    int w = (int)NSWidth(frameRect), h = (int)NSHeight(frameRect);
    if (w > 0 && h > 0)
        wpe_toplevel_resize(wpe_view_get_toplevel(IMPL->wpeView), w, h);
    wpe_view_focus_in(IMPL->wpeView);

    g_signal_connect(IMPL->wpeView, "buffer-rendered",
                     G_CALLBACK(onBufferRendered), self);
    g_signal_connect(IMPL->webView, "load-changed",
                     G_CALLBACK(onLoadChanged), self);
    g_signal_connect(IMPL->webView, "load-failed",
                     G_CALLBACK(onLoadFailed), self);
    g_signal_connect(IMPL->webView, "notify::title",
                     G_CALLBACK(onTitleChanged), self);
    g_signal_connect(IMPL->webView, "notify::estimated-load-progress",
                     G_CALLBACK(onProgressChanged), self);

    return self;
}

- (void)dealloc
{
    if (_impl) {
        if (IMPL->webView)
            g_signal_handlers_disconnect_by_data(IMPL->webView, self);
        if (IMPL->wpeView)
            g_signal_handlers_disconnect_by_data(IMPL->wpeView, self);
        [IMPL->rep release];
        if (IMPL->webView)
            g_object_unref(IMPL->webView);
        if (IMPL->display)
            g_object_unref(IMPL->display);
        free(_impl);
        _impl = NULL;
    }
    [super dealloc];
}

/* ---- internal callbacks ---- */

- (void)_bufferRendered:(void *)bufferPtr
{
    WPEBuffer *buffer = (WPEBuffer *)bufferPtr;
    if (!WPE_IS_BUFFER_SHM(buffer)) {
        NSLog(@"WebView: non-SHM buffer received (DMA-BUF path not implemented)");
        return;
    }
    int w = wpe_buffer_get_width(buffer), h = wpe_buffer_get_height(buffer);
    NSBitmapImageRep *rep = repFromSHM(WPE_BUFFER_SHM(buffer), w, h);
    if (rep) {
        [IMPL->rep release];
        IMPL->rep = rep;
        [self setNeedsDisplay:YES];
    }
    /* NOTE: do NOT call wpe_view_buffer_rendered() here — that function is what
     * *emits* this signal (WPEView.cpp:983), so calling it would recurse until
     * the stack overflows. We are an observer; the headless WPEView already
     * completed the frame before emitting. */
}

- (void)_loadChanged:(int)event
{
    id d = IMPL->frameLoadDelegate;
    switch (event) {
    case WEBKIT_LOAD_STARTED:
        [[NSNotificationCenter defaultCenter]
            postNotificationName:WebViewProgressStartedNotification object:self];
        if ([d respondsToSelector:@selector(webView:didStartProvisionalLoadForFrame:)])
            [d webView:self didStartProvisionalLoadForFrame:nil];
        break;
    case WEBKIT_LOAD_COMMITTED:
        if ([d respondsToSelector:@selector(webView:didCommitLoadForFrame:)])
            [d webView:self didCommitLoadForFrame:nil];
        break;
    case WEBKIT_LOAD_FINISHED:
        [[NSNotificationCenter defaultCenter]
            postNotificationName:WebViewProgressFinishedNotification object:self];
        if ([d respondsToSelector:@selector(webView:didFinishLoadForFrame:)])
            [d webView:self didFinishLoadForFrame:nil];
        break;
    default:
        break;
    }
}

- (void)_loadFailed:(const char *)uri message:(const char *)msg
{
    id d = IMPL->frameLoadDelegate;
    if ([d respondsToSelector:@selector(webView:didFailLoadWithError:forFrame:)]) {
        NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSString stringWithUTF8String:msg ?: "unknown"], NSLocalizedDescriptionKey,
            [NSString stringWithUTF8String:uri ?: ""], @"WebViewFailingURL", nil];
        NSError *err = [NSError errorWithDomain:@"WebKitErrorDomain" code:-1 userInfo:info];
        [d webView:self didFailLoadWithError:err forFrame:nil];
    }
}

- (void)_titleChanged
{
    id d = IMPL->frameLoadDelegate;
    if ([d respondsToSelector:@selector(webView:didReceiveTitle:forFrame:)])
        [d webView:self didReceiveTitle:[self mainFrameTitle] forFrame:nil];
}

- (void)_progressChanged
{
    id d = IMPL->frameLoadDelegate;
    if ([d respondsToSelector:@selector(webView:didChangeProgress:)])
        [d webView:self didChangeProgress:[self estimatedProgress]];
}

/* ---- NSView ---- */

- (BOOL)isFlipped        { return YES; }   /* match web coordinates */
- (BOOL)isOpaque         { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)drawRect:(NSRect)dirty
{
    if (!IMPL || !IMPL->rep) {
        [[NSColor whiteColor] set];
        NSRectFill(dirty);
        return;
    }

    NSRect b = [self bounds];
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];

    /* This view is flipped so that AppKit event coordinates line up with web
     * coordinates (origin top-left). NSBitmapImageRep draws bottom-up, so undo
     * the flip for the blit only. */
    if ([self isFlipped]) {
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:0.0 yBy:NSHeight(b)];
        [t scaleXBy:1.0 yBy:-1.0];
        [t concat];
    }
    [IMPL->rep drawInRect:NSMakeRect(0.0, 0.0, NSWidth(b), NSHeight(b))];

    [ctx restoreGraphicsState];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (IMPL && IMPL->wpeView && size.width > 0 && size.height > 0) {
        wpe_toplevel_resize(wpe_view_get_toplevel(IMPL->wpeView),
                            (int)size.width, (int)size.height);
    }
}

/* ---- Input ------------------------------------------------------------
 * NSEvent -> WPEEvent. The view is flipped, so our y already matches web
 * coordinates (origin top-left) and no flip is needed here.
 */

static WPEModifiers modifiersFromNSEvent(NSEvent *e)
{
    NSUInteger f = [e modifierFlags];
    int m = 0;
    if (f & NSControlKeyMask)  m |= WPE_MODIFIER_KEYBOARD_CONTROL;
    if (f & NSShiftKeyMask)    m |= WPE_MODIFIER_KEYBOARD_SHIFT;
    if (f & NSAlternateKeyMask) m |= WPE_MODIFIER_KEYBOARD_ALT;
    if (f & NSCommandKeyMask)  m |= WPE_MODIFIER_KEYBOARD_META;
    if (f & NSAlphaShiftKeyMask) m |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
    /* WebKit reads which buttons are held from the modifiers. Like the Wayland
     * backend, include the button on press and while dragging, and drop it on
     * release; otherwise pages see buttons == 0 and drags (sliders, text
     * selection) do nothing. */
    switch ([e type]) {
    case NSLeftMouseDown:
    case NSLeftMouseDragged:  m |= WPE_MODIFIER_POINTER_BUTTON1; break;
    case NSOtherMouseDown:
    case NSOtherMouseDragged: m |= WPE_MODIFIER_POINTER_BUTTON2; break;
    case NSRightMouseDown:
    case NSRightMouseDragged: m |= WPE_MODIFIER_POINTER_BUTTON3; break;
    default: break;
    }
    return (WPEModifiers)m;
}

static guint32 timeFromNSEvent(NSEvent *e)
{
    return (guint32)([e timestamp] * 1000.0);
}

/* Map an NSEvent key to an xkb keysym. Printable ASCII maps to itself;
 * everything else needs an explicit XKB_KEY_* constant. */
static guint keysymForNSEvent(NSEvent *e)
{
    NSString *chars = [e charactersIgnoringModifiers];
    if ([chars length] == 0)
        return 0;
    unichar c = [chars characterAtIndex:0];

    switch (c) {
    case NSUpArrowFunctionKey:    return XKB_KEY_Up;
    case NSDownArrowFunctionKey:  return XKB_KEY_Down;
    case NSLeftArrowFunctionKey:  return XKB_KEY_Left;
    case NSRightArrowFunctionKey: return XKB_KEY_Right;
    case NSPageUpFunctionKey:     return XKB_KEY_Page_Up;
    case NSPageDownFunctionKey:   return XKB_KEY_Page_Down;
    case NSHomeFunctionKey:       return XKB_KEY_Home;
    case NSEndFunctionKey:        return XKB_KEY_End;
    case NSDeleteFunctionKey:     return XKB_KEY_Delete;
    case NSInsertFunctionKey:     return XKB_KEY_Insert;
    case NSF1FunctionKey:         return XKB_KEY_F1;
    case NSF2FunctionKey:         return XKB_KEY_F2;
    case NSF3FunctionKey:         return XKB_KEY_F3;
    case NSF4FunctionKey:         return XKB_KEY_F4;
    case NSF5FunctionKey:         return XKB_KEY_F5;
    case NSF6FunctionKey:         return XKB_KEY_F6;
    case NSF7FunctionKey:         return XKB_KEY_F7;
    case NSF8FunctionKey:         return XKB_KEY_F8;
    case NSF9FunctionKey:         return XKB_KEY_F9;
    case NSF10FunctionKey:        return XKB_KEY_F10;
    case NSF11FunctionKey:        return XKB_KEY_F11;
    case NSF12FunctionKey:        return XKB_KEY_F12;
    case 0x7F: case 0x08:         return XKB_KEY_BackSpace;
    case 0x1B:                    return XKB_KEY_Escape;
    case '\r': case 0x03:         return XKB_KEY_Return;
    case '\t':                    return XKB_KEY_Tab;
    default: break;
    }
    if (c >= 0x20 && c < 0x7F)
        return (guint)c;              /* ASCII keysyms are the ASCII value */
    if (c >= 0x100)
        return (guint)c + 0x01000000; /* Unicode -> keysym */
    return 0;
}

- (void)_sendPointer:(NSEvent *)e type:(int)type button:(guint)button
{
    if (!IMPL || !IMPL->wpeView) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    /* WPE asserts press_count is zero for anything but a DOWN event. */
    guint pressCount = (type == WPE_EVENT_POINTER_DOWN) ? (guint)[e clickCount] : 0;
    WPEEvent *ev = wpe_event_pointer_button_new((WPEEventType)type, IMPL->wpeView,
        WPE_INPUT_SOURCE_MOUSE, timeFromNSEvent(e), modifiersFromNSEvent(e),
        button, p.x, p.y, pressCount);
    if (!ev) return;
    wpe_view_event(IMPL->wpeView, ev);
    wpe_event_unref(ev);
}

- (void)mouseDown:(NSEvent *)e        { [self _sendPointer:e type:WPE_EVENT_POINTER_DOWN button:1]; }
- (void)mouseUp:(NSEvent *)e          { [self _sendPointer:e type:WPE_EVENT_POINTER_UP   button:1]; }
- (void)rightMouseDown:(NSEvent *)e   { [self _sendPointer:e type:WPE_EVENT_POINTER_DOWN button:3]; }
- (void)rightMouseUp:(NSEvent *)e     { [self _sendPointer:e type:WPE_EVENT_POINTER_UP   button:3]; }
- (void)otherMouseDown:(NSEvent *)e   { [self _sendPointer:e type:WPE_EVENT_POINTER_DOWN button:2]; }
- (void)otherMouseUp:(NSEvent *)e     { [self _sendPointer:e type:WPE_EVENT_POINTER_UP   button:2]; }

- (void)_sendMove:(NSEvent *)e
{
    if (!IMPL || !IMPL->wpeView) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    WPEEvent *ev = wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, IMPL->wpeView,
        WPE_INPUT_SOURCE_MOUSE, timeFromNSEvent(e), modifiersFromNSEvent(e),
        p.x, p.y, [e deltaX], [e deltaY]);
    if (!ev) return;
    wpe_view_event(IMPL->wpeView, ev);
    wpe_event_unref(ev);
}

- (void)mouseMoved:(NSEvent *)e       { [self _sendMove:e]; }
- (void)mouseDragged:(NSEvent *)e     { [self _sendMove:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self _sendMove:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self _sendMove:e]; }

- (void)scrollWheel:(NSEvent *)e
{
    if (!IMPL || !IMPL->wpeView) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    /* AppKit scroll deltas are in "lines"; WebKit expects pixels for precise
     * deltas. Scale by a typical line height. */
    const double kLine = 40.0;
    WPEEvent *ev = wpe_event_scroll_new(IMPL->wpeView, WPE_INPUT_SOURCE_MOUSE,
        timeFromNSEvent(e), modifiersFromNSEvent(e),
        [e deltaX] * kLine, [e deltaY] * kLine,
        TRUE /* precise */, FALSE /* is_stop */, p.x, p.y);
    if (!ev) return;
    wpe_view_event(IMPL->wpeView, ev);
    wpe_event_unref(ev);
}

- (void)_sendKey:(NSEvent *)e type:(int)type
{
    if (!IMPL || !IMPL->wpeView) return;
    guint keysym = keysymForNSEvent(e);
    if (!keysym) return;
    /* X11 keycodes are evdev codes + 8; AppKit gives us the hardware code. */
    WPEEvent *ev = wpe_event_keyboard_new((WPEEventType)type, IMPL->wpeView,
        WPE_INPUT_SOURCE_KEYBOARD, timeFromNSEvent(e), modifiersFromNSEvent(e),
        (guint)[e keyCode] + 8, keysym);
    if (!ev) return;
    wpe_view_event(IMPL->wpeView, ev);
    wpe_event_unref(ev);
}

- (void)keyDown:(NSEvent *)e { [self _sendKey:e type:WPE_EVENT_KEYBOARD_KEY_DOWN]; }
- (void)keyUp:(NSEvent *)e   { [self _sendKey:e type:WPE_EVENT_KEYBOARD_KEY_UP]; }

- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window])
        [[self window] setAcceptsMouseMovedEvents:YES];
}

/* ---- Navigation ---- */

- (void)setMainFrameURL:(NSString *)urlString
{
    if (IMPL && IMPL->webView)
        webkit_web_view_load_uri(IMPL->webView, [urlString UTF8String]);
}

- (NSString *)mainFrameURL
{
    if (!IMPL || !IMPL->webView) return nil;
    const char *u = webkit_web_view_get_uri(IMPL->webView);
    return u ? [NSString stringWithUTF8String:u] : nil;
}

- (NSString *)mainFrameTitle
{
    if (!IMPL || !IMPL->webView) return nil;
    const char *t = webkit_web_view_get_title(IMPL->webView);
    return t ? [NSString stringWithUTF8String:t] : @"";
}

- (void)loadHTMLString:(NSString *)html baseURL:(NSString *)baseURL
{
    if (IMPL && IMPL->webView)
        webkit_web_view_load_html(IMPL->webView, [html UTF8String],
                                  baseURL ? [baseURL UTF8String] : NULL);
}

- (void)reload:(id)sender      { (void)sender; if (IMPL->webView) webkit_web_view_reload(IMPL->webView); }
- (void)stopLoading:(id)sender { (void)sender; if (IMPL->webView) webkit_web_view_stop_loading(IMPL->webView); }
- (void)goBack:(id)sender      { (void)sender; if (IMPL->webView) webkit_web_view_go_back(IMPL->webView); }
- (void)goForward:(id)sender   { (void)sender; if (IMPL->webView) webkit_web_view_go_forward(IMPL->webView); }
- (BOOL)canGoBack     { return IMPL->webView ? webkit_web_view_can_go_back(IMPL->webView) : NO; }
- (BOOL)canGoForward  { return IMPL->webView ? webkit_web_view_can_go_forward(IMPL->webView) : NO; }
- (BOOL)isLoading     { return IMPL->webView ? webkit_web_view_is_loading(IMPL->webView) : NO; }
- (double)estimatedProgress
{
    return IMPL->webView ? webkit_web_view_get_estimated_load_progress(IMPL->webView) : 0.0;
}

/* ---- JavaScript ---- */

typedef struct JSCallCtx { void (^handler)(NSString *, NSError *); } JSCallCtx;

static void onJSFinished(GObject *src, GAsyncResult *res, gpointer data)
{
    JSCallCtx *ctx = (JSCallCtx *)data;
    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(
        WEBKIT_WEB_VIEW(src), res, &error);
    if (!value) {
        NSError *e = [NSError errorWithDomain:@"WebKitJavaScriptErrorDomain"
                                         code:-1
                                     userInfo:[NSDictionary dictionaryWithObject:
                                        [NSString stringWithUTF8String:
                                            error ? error->message : "unknown"]
                                        forKey:NSLocalizedDescriptionKey]];
        if (error) g_error_free(error);
        ctx->handler(nil, e);
    } else {
        char *str = jsc_value_to_string(value);
        ctx->handler(str ? [NSString stringWithUTF8String:str] : @"", nil);
        g_free(str);
        g_object_unref(value);
    }
    Block_release(ctx->handler);
    free(ctx);
}

- (void)evaluateJavaScript:(NSString *)script
         completionHandler:(void (^)(NSString *, NSError *))handler
{
    if (!IMPL || !IMPL->webView) {
        if (handler) handler(nil, nil);
        return;
    }
    JSCallCtx *ctx = malloc(sizeof(JSCallCtx));
    ctx->handler = Block_copy(handler);
    webkit_web_view_evaluate_javascript(IMPL->webView,
        [script UTF8String], -1, NULL, NULL, NULL, onJSFinished, ctx);
}

- (NSBitmapImageRep *)currentFrameImageRep
{
    return (IMPL && IMPL->rep) ? [[IMPL->rep retain] autorelease] : nil;
}

/* ---- Delegate ---- */

- (void)setFrameLoadDelegate:(id)delegate { IMPL->frameLoadDelegate = delegate; }
- (id)frameLoadDelegate                   { return IMPL->frameLoadDelegate; }

@end
