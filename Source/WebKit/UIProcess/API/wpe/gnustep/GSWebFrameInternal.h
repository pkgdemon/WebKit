/* Internal to the framework: not installed. */
#import "GSWebFrame.h"

@interface WebFrame (Internal)
- (id)_initWithWebView:(WebView *)webView name:(NSString *)name;
@end
