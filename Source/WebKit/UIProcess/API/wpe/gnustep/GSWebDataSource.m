#import "GSWebDataSourceInternal.h"
#import "GSWebFrame.h"
#import "WebView.h"

@implementation WebDataSource

- (id)_initWithWebFrame:(WebFrame *)frame request:(NSURLRequest *)request
{
    self = [super init];
    if (!self)
        return nil;
    _webFrame = frame;       /* unretained, the frame owns us */
    _request = [request retain];
    return self;
}

- (void)dealloc
{
    [_request release];
    [super dealloc];
}

- (NSURLRequest *)request        { return _request; }
- (NSURLRequest *)initialRequest { return _request; }
- (NSString *)pageTitle          { return [[_webFrame webView] mainFrameTitle]; }
- (WebFrame *)webFrame           { return _webFrame; }

@end
