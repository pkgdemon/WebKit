#import "GSWebRunLoop.h"
#include <glib.h>

static NSTimer *sTimer = nil;

@implementation GSWebRunLoop

+ (void)pump:(NSTimer *)t
{
    (void)t;
    GMainContext *ctx = g_main_context_default();
    /* Drain everything currently pending, but bound the work so a busy page
     * cannot starve AppKit event handling. */
    int guard = 0;
    while (g_main_context_pending(ctx) && guard++ < 100)
        g_main_context_iteration(ctx, FALSE);
}

+ (void)start
{
    if (sTimer)
        return;
    /* ~120 Hz: comfortably above the 60 Hz frame callback so we never add a
     * whole frame of latency to input or rendering. */
    sTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0/120.0
                                               target:self
                                             selector:@selector(pump:)
                                             userInfo:nil
                                              repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:sTimer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:sTimer forMode:NSEventTrackingRunLoopMode];
}

+ (void)stop
{
    [sTimer invalidate];
    [sTimer release];
    sTimer = nil;
}

@end
