/* WebPreferences — settings for a WebView.
 *
 * Mirrors the classic WebKit API that GNUstep applications use. Preferences are
 * shared by identifier: asking for the same identifier twice returns the same
 * object, and changing it updates every WebView using it.
 */
#import <Foundation/Foundation.h>

/* Posted when any preferences object changes. The object is the WebPreferences. */
extern NSString * const WebPreferencesChangedNotification;

@interface WebPreferences : NSObject
{
    NSString *_identifier;
    NSMutableDictionary *_values;
    BOOL _autosaves;
}

+ (WebPreferences *)standardPreferences;

/* Returns the existing preferences for this identifier, if there is one. */
- (id)initWithIdentifier:(NSString *)identifier;
- (NSString *)identifier;

/* Written to the user defaults whenever they change. */
- (void)setAutosaves:(BOOL)flag;
- (BOOL)autosaves;

- (void)setJavaScriptEnabled:(BOOL)flag;
- (BOOL)isJavaScriptEnabled;

- (void)setStandardFontFamily:(NSString *)family;
- (NSString *)standardFontFamily;
- (void)setSerifFontFamily:(NSString *)family;
- (NSString *)serifFontFamily;
- (void)setSansSerifFontFamily:(NSString *)family;
- (NSString *)sansSerifFontFamily;
- (void)setFixedFontFamily:(NSString *)family;
- (NSString *)fixedFontFamily;

- (void)setDefaultFontSize:(int)size;
- (int)defaultFontSize;
- (void)setDefaultFixedFontSize:(int)size;
- (int)defaultFixedFontSize;
- (void)setMinimumFontSize:(int)size;
- (int)minimumFontSize;

- (void)setLoadsImagesAutomatically:(BOOL)flag;
- (BOOL)loadsImagesAutomatically;

@end
