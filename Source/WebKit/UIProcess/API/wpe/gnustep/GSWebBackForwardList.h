/* WebBackForwardList — the back/forward history of a WebView.
 *
 * A thin view onto WebKit's own list: applications use it to enable and
 * disable their Back and Forward buttons.
 */
#import <Foundation/Foundation.h>

@class WebView;

@interface WebBackForwardList : NSObject
{
    WebView *_webView;   /* unretained: the view owns its list */
}

- (int)backListCount;
- (int)forwardListCount;

- (void)goBack;
- (void)goForward;

@end
