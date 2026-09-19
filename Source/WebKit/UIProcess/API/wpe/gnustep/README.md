# GNUstep API layer for WPE WebKit

Provides `WebKit.framework` for GNUstep: a `WebView : NSView` backed by the real
WebKit engine, so GNUstep/AppKit applications can embed web content.

Built only when `ENABLE_WPE_GNUSTEP_API` is enabled, which defaults to
developer-mode builds — exactly like `ENABLE_WPE_QT_API`, whose structure this
mirrors (`UIProcess/API/wpe/qt6`).

## Layout

| File | Purpose |
|---|---|
| `WebView.{h,m}` | The AppKit-facing `NSView`. Owns a `WebKitWebView` on a headless `WPEDisplay`, converts each rendered frame into an `NSBitmapImageRep`, and translates `NSEvent` into `WPEEvent`. |
| `GSWebRunLoop.{h,m}` | Pumps the GLib default `GMainContext` from `NSRunLoop`. |
| `GSWebFrame.{h,m}` | `WebFrame`: the main frame, installed as `<WebKit/WebFrame.h>`. |
| `GSWebPreferences.{h,m}` | `WebPreferences`: settings shared by identifier, installed as `<WebKit/WebPreferences.h>`. |
| `GSWebBackForwardList.{h,m}` | `WebBackForwardList`, installed as `<WebKit/WebBackForwardList.h>`. |
| `WebKitGNUstep.h` | Umbrella header. |

The `GS` prefixes exist only because WebKit already has internal headers named
`WebFrame.h`, `WebPreferences.h` and `WebBackForwardList.h`; the classes and the
installed headers use the classic WebKit names, so applications written against
Apple's API compile unchanged.

The sources are plain Objective-C, not Objective-C++: GNUstep's AppKit headers
are not guaranteed to be valid C++ (`NSImage.h` declares a bitfield named
`template`), and the WPE API used here is C.

## Design notes

- **Threading.** WebKit's UIProcess is not thread-safe and WTF's `RunLoopGLib`
  owns the default `GMainContext`, so every WebKit call happens on the AppKit
  main thread and the GLib loop is driven from `NSRunLoop` rather than a
  separate thread.
- **Pixel format.** Frames arrive as premultiplied ARGB8888, i.e. `B,G,R,A` in
  memory. `NSBitmapImageRep` expects `R,G,B,A`, so red and blue are swapped.
  Stride may exceed `width * 4`, so rows are copied individually.
- **Coordinates.** The view is flipped so AppKit event coordinates match web
  coordinates. `NSBitmapImageRep` draws bottom-up, so `-drawRect:` undoes the
  flip for the blit only.
- **Do not call `wpe_view_buffer_rendered()` from a `buffer-rendered` handler.**
  That function *emits* the signal (`WPEPlatform/wpe/WPEView.cpp`), so calling it
  recurses until the stack overflows.
- `wpe_event_pointer_button_new()` asserts `press_count == 0` for any type other
  than `WPE_EVENT_POINTER_DOWN`, and event constructors return NULL when an
  assertion fails, so results must be NULL-checked before `wpe_event_unref()`.

## Possible refinement

This layer currently uses the stock headless `WPEDisplay` and observes the
`buffer-rendered` signal. The qt6 layer instead subclasses
`WPEDisplay`/`WPEToplevel`/`WPEView` (`WPEDisplayQtQuick`, `WPEToplevelQtQuick`,
`WPEViewQtQuick`). Doing the same here — `WPEDisplayGNUstep`, `WPEToplevelGNUstep`,
`WPEViewGNUstep` implementing `render_buffer()` directly — would give tighter
control over frame lifetime and damage rectangles.
