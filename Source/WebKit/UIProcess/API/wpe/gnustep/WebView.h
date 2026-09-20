/* WebView — a real WebKit web view for GNUstep.
 * Backed by WPE WebKit; frames arrive as shared-memory buffers and are
 * blitted into this NSView. */
#import <AppKit/AppKit.h>

@class WebView;
@class WebFrame;
@class WebPreferences;
@class WebBackForwardList;

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

/* Sent when the page asks for a new window (window.open, target=_blank).
 * The application creates the view and the window that shows it. */
@protocol WebUIDelegate <NSObject>
@optional
- (WebView *)webView:(WebView *)sender createWebViewWithRequest:(NSURLRequest *)request;
- (void)webViewShow:(WebView *)sender;
@end

@interface WebView : NSView
{
    void *_impl;   /* opaque: GSWebViewImpl* */
}

/* The main frame. WPE exposes no per-frame objects, so this is the only frame;
 * it is what frame-load delegates are passed. */
- (WebFrame *)mainFrame;

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

/* Classic WebKit spellings of the above, for applications written against
 * Apple's API. */
- (BOOL)goBack;
- (BOOL)goForward;
- (void)takeStringURLFrom:(id)sender;   /* target of a URL text field */

/* JavaScript */
- (void)evaluateJavaScript:(NSString *)script
         completionHandler:(void (^)(NSString *result, NSError *error))handler;

/* Current rendered frame, or nil if nothing has been painted yet.
 * Useful for snapshots and for tests. */
- (NSBitmapImageRep *)currentFrameImageRep;

/* Editing. The page and the AppKit pasteboard are kept in step: copy and cut
 * put the selection on the general pasteboard, and paste inserts what is on
 * it into the page. Menu items sending these to the first responder work
 * without the application doing anything. */
- (void)copy:(id)sender;
- (void)cut:(id)sender;
- (void)paste:(id)sender;
- (void)selectAll:(id)sender;
- (void)delete:(id)sender;
- (NSString *)selectedText;   /* empty when nothing is selected */

/* Text zoom */
- (void)makeTextLarger:(id)sender;
- (void)makeTextSmaller:(id)sender;
- (void)makeTextStandardSize:(id)sender;

/* Settings, shared by identifier. */
- (WebPreferences *)preferences;
- (void)setPreferences:(WebPreferences *)preferences;
- (void)setPreferencesIdentifier:(NSString *)identifier;
- (NSString *)preferencesIdentifier;

/* History */
- (WebBackForwardList *)backForwardList;
- (void)setMaintainsBackForwardList:(BOOL)flag;

/* Accepted for source compatibility; WPE has no view groups. */
- (void)setGroupName:(NSString *)groupName;
- (NSString *)groupName;

/* Delegates */
- (void)setFrameLoadDelegate:(id)delegate;   /* WebFrameLoadDelegate */
- (id)frameLoadDelegate;
- (void)setUIDelegate:(id)delegate;          /* WebUIDelegate */
- (id)uiDelegate;

@end
