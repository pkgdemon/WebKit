/* WebDataSource — the data behind a frame's page.
 *
 * WPE does not expose a frame's loader to applications, so this reports what
 * the view knows about the page: the request it is showing and its title.
 */
#import <Foundation/Foundation.h>

@class WebFrame;

@interface WebDataSource : NSObject
{
    WebFrame *_webFrame;      /* unretained: the frame owns its data sources */
    NSURLRequest *_request;
}

- (NSURLRequest *)request;
- (NSURLRequest *)initialRequest;
- (NSString *)pageTitle;
- (WebFrame *)webFrame;

@end
