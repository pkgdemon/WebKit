#import "GSWebBackForwardListInternal.h"
#import "WebView.h"

@implementation WebBackForwardList

- (id)_initWithWebView:(WebView *)webView
{
    self = [super init];
    if (!self)
        return nil;
    _webView = webView;   /* unretained, the view owns us */
    return self;
}

- (int)backListCount    { return [_webView _backListCount]; }
- (int)forwardListCount { return [_webView _forwardListCount]; }

- (void)goBack    { [_webView goBack:nil]; }
- (void)goForward { [_webView goForward:nil]; }

@end
