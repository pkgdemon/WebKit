/* Internal to the framework: not installed. */
#import "GSWebBackForwardList.h"
#import "WebView.h"

@interface WebBackForwardList (Internal)
- (id)_initWithWebView:(WebView *)webView;
@end

@interface WebView (GSBackForwardInternal)
- (int)_backListCount;
- (int)_forwardListCount;
@end
