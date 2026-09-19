/* Internal to the framework: not installed. */
#import "GSWebDataSource.h"

@interface WebDataSource (Internal)
- (id)_initWithWebFrame:(WebFrame *)frame request:(NSURLRequest *)request;
@end
