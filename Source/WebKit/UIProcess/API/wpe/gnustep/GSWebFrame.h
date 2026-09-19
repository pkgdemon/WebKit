/* WebFrame — the frame of a WebView.
 *
 * WPE WebKit does not expose per-frame objects to applications, so this is the
 * main frame only: enough for the classic WebKit API that GNUstep applications
 * are written against, where -[[webView mainFrame] loadRequest:] loads a page
 * and frame-load delegates compare their frame with -[sender mainFrame].
 */
#import <Foundation/Foundation.h>

@class WebView;
@class WebDataSource;

@interface WebFrame : NSObject
{
    WebView *_webView;   /* unretained: the view owns its frame */
    NSString *_name;
    WebDataSource *_dataSource;
}

- (void)loadRequest:(NSURLRequest *)request;
- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL;

- (WebView *)webView;
- (NSString *)name;

/* What the frame is showing, and what it is loading. WPE has no separate
 * provisional loader, so both describe the frame's current request. */
- (WebDataSource *)dataSource;
- (WebDataSource *)provisionalDataSource;

/* The main frame has no parent and, since only the main frame is exposed, no
 * children; these return nil and an empty array. */
- (WebFrame *)parentFrame;
- (NSArray *)childFrames;

@end
