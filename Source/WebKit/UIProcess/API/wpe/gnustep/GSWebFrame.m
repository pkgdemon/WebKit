#import "GSWebFrameInternal.h"
#import "WebView.h"
#import "GSWebDataSourceInternal.h"

@implementation WebFrame

- (id)_initWithWebView:(WebView *)webView name:(NSString *)name
{
    self = [super init];
    if (!self)
        return nil;
    _webView = webView;              /* unretained, the view owns us */
    _name = [name copy];
    return self;
}

- (void)dealloc
{
    [_dataSource release];
    [_name release];
    [super dealloc];
}

- (void)loadRequest:(NSURLRequest *)request
{
    NSString *url = [[request URL] absoluteString];
    if ([url length])
        [_webView setMainFrameURL:url];
}

- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL
{
    [_webView loadHTMLString:string baseURL:[baseURL absoluteString]];
}

- (WebDataSource *)dataSource
{
    NSString *url = [_webView mainFrameURL];
    if (![url length])
        return nil;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    [_dataSource release];
    _dataSource = [[WebDataSource alloc] _initWithWebFrame:self request:request];
    return _dataSource;
}

- (WebDataSource *)provisionalDataSource { return [self dataSource]; }

- (WebView *)webView      { return _webView; }
- (NSString *)name        { return _name; }
- (WebFrame *)parentFrame { return nil; }
- (NSArray *)childFrames  { return [NSArray array]; }

@end
