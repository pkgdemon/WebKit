/* WebView — a real WebKit web view for GNUstep.
 * Backed by WPE WebKit; frames arrive as shared-memory buffers and are
 * blitted into this NSView. */
#import <AppKit/AppKit.h>

@class WebView;

extern NSString * const WebViewProgressStartedNotification;
extern NSString * const WebViewProgressFinishedNotification;

@protocol WebFrameLoadDelegate <NSObject>
@optional
- (void)webView:(WebView *)sender didStartProvisionalLoadForFrame:(id)frame;
- (void)webView:(WebView *)sender didCommitLoadForFrame:(id)frame;
- (void)webView:(WebView *)sender didFinishLoadForFrame:(id)frame;
- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(id)frame;
- (void)webView:(WebView *)sender didReceiveTitle:(NSString *)title forFrame:(id)frame;
- (void)webView:(WebView *)sender didChangeProgress:(double)progress;
@end

@interface WebView : NSView
{
    void *_impl;   /* opaque: GSWebViewImpl* */
}

/* Navigation */
- (void)setMainFrameURL:(NSString *)urlString;
- (NSString *)mainFrameURL;
- (NSString *)mainFrameTitle;
- (void)loadHTMLString:(NSString *)html baseURL:(NSString *)baseURL;
- (void)reload:(id)sender;
- (void)stopLoading:(id)sender;
- (void)goBack:(id)sender;
- (void)goForward:(id)sender;
- (BOOL)canGoBack;
- (BOOL)canGoForward;
- (double)estimatedProgress;
- (BOOL)isLoading;

/* JavaScript */
- (void)evaluateJavaScript:(NSString *)script
         completionHandler:(void (^)(NSString *result, NSError *error))handler;

/* Current rendered frame, or nil if nothing has been painted yet.
 * Useful for snapshots and for tests. */
- (NSBitmapImageRep *)currentFrameImageRep;

/* Delegate */
- (void)setFrameLoadDelegate:(id<WebFrameLoadDelegate>)delegate;
- (id<WebFrameLoadDelegate>)frameLoadDelegate;

@end
