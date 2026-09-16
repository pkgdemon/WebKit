/* Pumps the GLib default GMainContext from the AppKit NSRunLoop.
 *
 * WebKit's UIProcess is not thread-safe and WTF's RunLoopGLib owns the default
 * GMainContext, so every WebKit call must happen on the AppKit main thread.
 * We therefore drive GLib's loop from inside NSRunLoop rather than running it
 * on a thread of its own.
 *
 * v1 is timer-driven (simple, obviously correct). The fd-driven version using
 * GNUstep's -addEvent:type:watcher:forMode: is planned; see GNUSTEP_WEBKIT_PLAN.md.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface GSWebRunLoop : NSObject
+ (void)start;    /* idempotent */
+ (void)stop;
@end
