#import "WebView.h"
#import "GSWebRunLoop.h"
#import "GSWebFrameInternal.h"
#import "GSWebBackForwardListInternal.h"
#import "GSWebPreferences.h"

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
    WebFrame        *mainFrame;
    WebBackForwardList *backForwardList;
    WebPreferences  *preferences;
    NSString        *groupName;
    id               uiDelegate;          /* unretained, per AppKit convention */
    WPEClipboard    *clipboard;           /* owned by the display */
    gint64           lastWPEClipboardCount;
    NSInteger        lastPasteboardCount;
    NSTimer         *clipboardTimer;      /* keeps the two clipboards in step */
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
- (void)_setUpWebView;
- (void)_applyPreferences;
- (void)_syncClipboard:(NSTimer *)timer;
- (WebView *)_createWebViewWithURI:(const char *)uri;
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

/* The page asked for a new window. Let the application make one; WebKit itself
 * gets NULL, because the new view has its own web process and cannot be handed
 * back to the opener. The request is loaded into the new view instead, so
 * window.open() and target=_blank open the page but share no script context. */
static WebKitWebView *onCreate(WebKitWebView *v, WebKitNavigationAction *action, gpointer data)
{
    (void)v;
    WebKitURIRequest *request = action ? webkit_navigation_action_get_request(action) : NULL;
    [(WebView *)data _createWebViewWithURI:(request ? webkit_uri_request_get_uri(request) : NULL)];
    return NULL;
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
    [self _setUpWebView];
    return self;
}

/* Gorm and Interface Builder archives instantiate the view this way. */
- (id)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    [self _setUpWebView];
    return self;
}

- (void)_setUpWebView
{
    NSRect frameRect = [self frame];

    [GSWebRunLoop start];
    setUpPersistentCookieStorage();

    _impl = calloc(1, sizeof(GSWebViewImpl));
    IMPL->owner = self;

    IMPL->display = wpe_display_headless_new();
    if (!IMPL->display) {
        NSLog(@"WebView: failed to create WPE headless display");
        return;
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
        return;
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
    g_signal_connect(IMPL->webView, "create",
                     G_CALLBACK(onCreate), self);

    /* Web pages have their own clipboard in WPE, which nothing else on the
     * desktop can see. Mirror it to and from AppKit's general pasteboard so a
     * page's own copy buttons, and pasting into a page, work. */
    /* WebKit's pasteboard proxy uses the primary display's clipboard, which is
     * not always this view's display, so watch that one. */
    IMPL->clipboard = wpe_display_get_clipboard(wpe_display_get_primary() ?: IMPL->display);
    if (IMPL->clipboard) {
        IMPL->lastWPEClipboardCount = wpe_clipboard_get_change_count(IMPL->clipboard);
        IMPL->lastPasteboardCount = [[NSPasteboard generalPasteboard] changeCount];
        IMPL->clipboardTimer = [[NSTimer scheduledTimerWithTimeInterval:0.25
                                                                 target:self
                                                               selector:@selector(_syncClipboard:)
                                                               userInfo:nil
                                                                repeats:YES] retain];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_preferencesChanged:)
                                                 name:WebPreferencesChangedNotification
                                               object:nil];
    [self _applyPreferences];
}

- (void)dealloc
{
    if (_impl) {
        if (IMPL->webView)
            g_signal_handlers_disconnect_by_data(IMPL->webView, self);
        if (IMPL->wpeView)
            g_signal_handlers_disconnect_by_data(IMPL->wpeView, self);
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [IMPL->rep release];
        [IMPL->mainFrame release];
        [IMPL->backForwardList release];
        [IMPL->preferences release];
        [IMPL->groupName release];
        [IMPL->clipboardTimer invalidate];
        [IMPL->clipboardTimer release];
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
            [d webView:self didStartProvisionalLoadForFrame:[self mainFrame]];
        break;
    case WEBKIT_LOAD_COMMITTED:
        if ([d respondsToSelector:@selector(webView:didCommitLoadForFrame:)])
            [d webView:self didCommitLoadForFrame:[self mainFrame]];
        break;
    case WEBKIT_LOAD_FINISHED:
        [[NSNotificationCenter defaultCenter]
            postNotificationName:WebViewProgressFinishedNotification object:self];
        if ([d respondsToSelector:@selector(webView:didFinishLoadForFrame:)])
            [d webView:self didFinishLoadForFrame:[self mainFrame]];
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
        [d webView:self didFailLoadWithError:err forFrame:[self mainFrame]];
    }
}

- (void)_titleChanged
{
    id d = IMPL->frameLoadDelegate;
    if ([d respondsToSelector:@selector(webView:didReceiveTitle:forFrame:)])
        [d webView:self didReceiveTitle:[self mainFrameTitle] forFrame:[self mainFrame]];
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

/* Keep the web content the same size as the view. Otherwise the frame is
 * stretched to fit in -drawRect: while input stays in view coordinates, so
 * clicks land away from what is drawn. */
- (void)_resizeWebContent
{
    NSSize size = [self frame].size;
    if (IMPL && IMPL->wpeView && size.width > 0 && size.height > 0) {
        wpe_toplevel_resize(wpe_view_get_toplevel(IMPL->wpeView),
                            (int)size.width, (int)size.height);
    }
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self _resizeWebContent];
}

/* GNUstep's -setFrame: does not go through -setFrameSize:, and containers
 * such as NSTabView size their views with it. */
- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    [self _resizeWebContent];
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

- (WebFrame *)mainFrame
{
    if (!IMPL)
        return nil;
    if (!IMPL->mainFrame)
        IMPL->mainFrame = [[WebFrame alloc] _initWithWebView:self name:@""];
    return IMPL->mainFrame;
}

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
/* Classic WebKit spellings: these return whether the move happened. */
- (BOOL)goBack
{
    if (![self canGoBack])
        return NO;
    [self goBack:nil];
    return YES;
}

- (BOOL)goForward
{
    if (![self canGoForward])
        return NO;
    [self goForward:nil];
    return YES;
}

/* Target of a URL text field: load whatever it holds. */
- (void)takeStringURLFrom:(id)sender
{
    NSString *url = [sender respondsToSelector:@selector(stringValue)] ? [sender stringValue] : nil;
    if ([url length])
        [self setMainFrameURL:url];
}

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
        if (ctx->handler) ctx->handler(nil, e);
    } else {
        char *str = jsc_value_to_string(value);
        if (ctx->handler) ctx->handler(str ? [NSString stringWithUTF8String:str] : @"", nil);
        g_free(str);
        g_object_unref(value);
    }
    if (ctx->handler) Block_release(ctx->handler);
    free(ctx);
}

- (void)evaluateJavaScript:(NSString *)script
         completionHandler:(void (^)(NSString *, NSError *))handler
{
    if (!IMPL || !IMPL->webView) {
        if (handler) handler(nil, nil);
        return;
    }
    /* The completion handler is optional: scripts are often run for effect. */
    JSCallCtx *ctx = malloc(sizeof(JSCallCtx));
    ctx->handler = handler ? Block_copy(handler) : NULL;
    webkit_web_view_evaluate_javascript(IMPL->webView,
        [script UTF8String], -1, NULL, NULL, NULL, onJSFinished, ctx);
}

- (NSBitmapImageRep *)currentFrameImageRep
{
    return (IMPL && IMPL->rep) ? [[IMPL->rep retain] autorelease] : nil;
}

/* ---- Editing and the pasteboard ------------------------------------------
 * WPE has its own clipboard, which on a headless display is not connected to
 * anything the rest of the desktop can see, so the selection is moved through
 * AppKit's general pasteboard instead: -copy:/-cut: read the page's selection
 * and write it there, -paste: inserts the pasteboard's text into the page.
 */

- (NSString *)selectedText
{
    __block NSString *text = nil;
    __block BOOL done = NO;

    if (!IMPL || !IMPL->webView)
        return @"";

    [self evaluateJavaScript:@"window.getSelection ? String(window.getSelection()) : ''"
           completionHandler:^(NSString *result, NSError *error) {
        (void)error;
        text = [result copy];
        done = YES;
    }];

    /* The web process replies on the GLib loop, which GSWebRunLoop pumps from
     * this run loop, so wait briefly rather than returning nothing. */
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!done && [until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return text ? [text autorelease] : @"";
}

- (void)_putSelectionOnPasteboard
{
    NSString *text = [self selectedText];

    if (![text length])
        return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pb setString:text forType:NSStringPboardType];
}

- (void)copy:(id)sender
{
    (void)sender;
    if (!IMPL || !IMPL->webView)
        return;
    [self _putSelectionOnPasteboard];
    webkit_web_view_execute_editing_command(IMPL->webView, WEBKIT_EDITING_COMMAND_COPY);
}

- (void)cut:(id)sender
{
    (void)sender;
    if (!IMPL || !IMPL->webView)
        return;
    [self _putSelectionOnPasteboard];
    webkit_web_view_execute_editing_command(IMPL->webView, WEBKIT_EDITING_COMMAND_CUT);
}

- (void)paste:(id)sender
{
    (void)sender;
    if (!IMPL || !IMPL->webView)
        return;

    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSStringPboardType];
    if ([text length]) {
        /* Insert the pasteboard's own text: WPE's clipboard is separate from
         * AppKit's, so WEBKIT_EDITING_COMMAND_PASTE alone would paste whatever
         * was last copied inside the page. */
        webkit_web_view_execute_editing_command_with_argument(IMPL->webView,
            "InsertText", [text UTF8String]);
    } else {
        webkit_web_view_execute_editing_command(IMPL->webView, WEBKIT_EDITING_COMMAND_PASTE);
    }
}

- (void)selectAll:(id)sender
{
    (void)sender;
    if (IMPL && IMPL->webView)
        webkit_web_view_execute_editing_command(IMPL->webView, WEBKIT_EDITING_COMMAND_SELECT_ALL);
}

- (void)delete:(id)sender
{
    (void)sender;
    if (IMPL && IMPL->webView)
        webkit_web_view_execute_editing_command(IMPL->webView, "Delete");
}

/* Copy what a page put on WPE's clipboard to the general pasteboard, and what
 * other applications put on the pasteboard back to the page's clipboard. Only
 * one direction runs per tick, so the two cannot chase each other. */
- (void)_syncClipboard:(NSTimer *)timer
{
    (void)timer;
    if (!IMPL || !IMPL->clipboard)
        return;

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    gint64 wpeCount = wpe_clipboard_get_change_count(IMPL->clipboard);

    if (wpeCount != IMPL->lastWPEClipboardCount) {
        IMPL->lastWPEClipboardCount = wpeCount;

        /* Content set by a page in this process is held locally, where
         * wpe_clipboard_read_text() does not see it, so ask for the content
         * object first and only then fall back to reading a format. */
        NSString *text = nil;
        WPEClipboardContent *content = wpe_clipboard_get_content(IMPL->clipboard);
        const char *local = content ? wpe_clipboard_content_get_text(content) : NULL;
        char *readBack = NULL;

        if (local && *local)
            text = [NSString stringWithUTF8String:local];
        else {
            readBack = wpe_clipboard_read_text(IMPL->clipboard, "text/plain;charset=utf-8", NULL);
            if (!readBack)
                readBack = wpe_clipboard_read_text(IMPL->clipboard, "text/plain", NULL);
            if (readBack && *readBack)
                text = [NSString stringWithUTF8String:readBack];
        }

        if ([text length]) {
            [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
            [pb setString:text forType:NSStringPboardType];
            IMPL->lastPasteboardCount = [pb changeCount];
        }
        if (readBack)
            g_free(readBack);
        return;
    }

    NSInteger pbCount = [pb changeCount];
    if (pbCount != IMPL->lastPasteboardCount) {
        IMPL->lastPasteboardCount = pbCount;
        NSString *text = [pb stringForType:NSStringPboardType];
        if ([text length]) {
            WPEClipboardContent *content = wpe_clipboard_content_new();
            wpe_clipboard_content_set_text(content, [text UTF8String]);
            wpe_clipboard_set_content(IMPL->clipboard, content);
            wpe_clipboard_content_unref(content);
            IMPL->lastWPEClipboardCount = wpe_clipboard_get_change_count(IMPL->clipboard);
        }
    }
}

/* ---- Text zoom ---- */

- (void)makeTextLarger:(id)sender
{
    (void)sender;
    if (IMPL && IMPL->webView)
        webkit_web_view_set_zoom_level(IMPL->webView, webkit_web_view_get_zoom_level(IMPL->webView) * 1.1);
}

- (void)makeTextSmaller:(id)sender
{
    (void)sender;
    if (IMPL && IMPL->webView)
        webkit_web_view_set_zoom_level(IMPL->webView, webkit_web_view_get_zoom_level(IMPL->webView) / 1.1);
}

- (void)makeTextStandardSize:(id)sender
{
    (void)sender;
    if (IMPL && IMPL->webView)
        webkit_web_view_set_zoom_level(IMPL->webView, 1.0);
}

/* ---- Preferences ---- */

- (WebPreferences *)preferences
{
    if (!IMPL)
        return nil;
    if (!IMPL->preferences)
        IMPL->preferences = [[WebPreferences standardPreferences] retain];
    return IMPL->preferences;
}

- (void)setPreferences:(WebPreferences *)preferences
{
    if (!IMPL || IMPL->preferences == preferences)
        return;
    [IMPL->preferences release];
    IMPL->preferences = [preferences retain];
    [self _applyPreferences];
}

- (void)setPreferencesIdentifier:(NSString *)identifier
{
    WebPreferences *prefs = [[WebPreferences alloc] initWithIdentifier:identifier];
    [self setPreferences:prefs];
    [prefs release];
}

- (NSString *)preferencesIdentifier { return [[self preferences] identifier]; }

- (void)_preferencesChanged:(NSNotification *)note
{
    if ([note object] == [self preferences])
        [self _applyPreferences];
}

- (void)_applyPreferences
{
    if (!IMPL || !IMPL->webView)
        return;
    WebPreferences *p = [self preferences];
    WebKitSettings *settings = webkit_web_view_get_settings(IMPL->webView);
    g_object_set(settings,
        "enable-javascript", [p isJavaScriptEnabled] ? TRUE : FALSE,
        "auto-load-images", [p loadsImagesAutomatically] ? TRUE : FALSE,
        "default-font-family", [[p standardFontFamily] UTF8String],
        "serif-font-family", [[p serifFontFamily] UTF8String],
        "sans-serif-font-family", [[p sansSerifFontFamily] UTF8String],
        "monospace-font-family", [[p fixedFontFamily] UTF8String],
        "default-font-size", (guint32)[p defaultFontSize],
        "default-monospace-font-size", (guint32)[p defaultFixedFontSize],
        "minimum-font-size", (guint32)[p minimumFontSize],
        NULL);
}

/* ---- History ---- */

- (WebBackForwardList *)backForwardList
{
    if (!IMPL)
        return nil;
    if (!IMPL->backForwardList)
        IMPL->backForwardList = [[WebBackForwardList alloc] _initWithWebView:self];
    return IMPL->backForwardList;
}

/* WPE always keeps a back/forward list. */
- (void)setMaintainsBackForwardList:(BOOL)flag { (void)flag; }

- (int)_backListCount
{
    if (!IMPL || !IMPL->webView)
        return 0;
    GList *list = webkit_back_forward_list_get_back_list(webkit_web_view_get_back_forward_list(IMPL->webView));
    int count = (int)g_list_length(list);
    g_list_free(list);
    return count;
}

- (int)_forwardListCount
{
    if (!IMPL || !IMPL->webView)
        return 0;
    GList *list = webkit_back_forward_list_get_forward_list(webkit_web_view_get_back_forward_list(IMPL->webView));
    int count = (int)g_list_length(list);
    g_list_free(list);
    return count;
}

- (void)setGroupName:(NSString *)groupName
{
    if (!IMPL)
        return;
    [IMPL->groupName release];
    IMPL->groupName = [groupName copy];
}

- (NSString *)groupName { return IMPL ? IMPL->groupName : nil; }

/* ---- New windows ---- */

- (WebView *)_createWebViewWithURI:(const char *)uri
{
    id d = IMPL ? IMPL->uiDelegate : nil;
    if (![d respondsToSelector:@selector(webView:createWebViewWithRequest:)])
        return nil;

    NSURLRequest *request = nil;
    if (uri && *uri) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:uri]];
        if (url)
            request = [NSURLRequest requestWithURL:url];
    }

    WebView *created = [d webView:self createWebViewWithRequest:request];
    if (!created)
        return nil;

    /* Apple's API loads the request into the returned view. Applications that
     * load it themselves simply end up loading the same URL. */
    if (request && ![[created mainFrameURL] length])
        [[created mainFrame] loadRequest:request];

    if ([d respondsToSelector:@selector(webViewShow:)])
        [d webViewShow:created];
    return created;
}

/* ---- Delegates ---- */

- (void)setFrameLoadDelegate:(id)delegate { IMPL->frameLoadDelegate = delegate; }
- (id)frameLoadDelegate                   { return IMPL->frameLoadDelegate; }
- (void)setUIDelegate:(id)delegate        { IMPL->uiDelegate = delegate; }
- (id)uiDelegate                          { return IMPL->uiDelegate; }

@end
