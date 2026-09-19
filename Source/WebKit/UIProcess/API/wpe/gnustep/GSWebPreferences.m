#import "GSWebPreferences.h"

NSString * const WebPreferencesChangedNotification = @"WebPreferencesChangedNotification";

/* Keys are also the user defaults keys, under WebPreferences-<identifier>. */
static NSString * const kJavaScriptEnabled = @"JavaScriptEnabled";
static NSString * const kStandardFont      = @"StandardFontFamily";
static NSString * const kSerifFont         = @"SerifFontFamily";
static NSString * const kSansSerifFont     = @"SansSerifFontFamily";
static NSString * const kFixedFont         = @"FixedFontFamily";
static NSString * const kDefaultFontSize   = @"DefaultFontSize";
static NSString * const kDefaultFixedSize  = @"DefaultFixedFontSize";
static NSString * const kMinimumFontSize   = @"MinimumFontSize";
static NSString * const kLoadsImages       = @"LoadsImagesAutomatically";

/* identifier -> WebPreferences, so the same identifier is the same object. */
static NSMutableDictionary *sByIdentifier = nil;

@interface WebPreferences (GSPrivate)
- (NSString *)_defaultsKey;
- (void)_set:(id)value forKey:(NSString *)key;
@end

@implementation WebPreferences

+ (WebPreferences *)standardPreferences
{
    static WebPreferences *standard = nil;
    if (!standard)
        standard = [[WebPreferences alloc] initWithIdentifier:nil];
    return standard;
}

- (id)initWithIdentifier:(NSString *)identifier
{
    /* Apple's API shares one object per identifier. */
    WebPreferences *existing = [sByIdentifier objectForKey:(identifier ?: @"")];
    if (existing) {
        [self release];
        return [existing retain];
    }

    self = [super init];
    if (!self)
        return nil;

    _identifier = [identifier copy];
    _values = [[NSMutableDictionary alloc] init];

    /* Defaults matching WebKit's own. */
    [_values setObject:[NSNumber numberWithBool:YES] forKey:kJavaScriptEnabled];
    [_values setObject:[NSNumber numberWithBool:YES] forKey:kLoadsImages];
    [_values setObject:@"Sans" forKey:kStandardFont];
    [_values setObject:@"Serif" forKey:kSerifFont];
    [_values setObject:@"Sans" forKey:kSansSerifFont];
    [_values setObject:@"Monospace" forKey:kFixedFont];
    [_values setObject:[NSNumber numberWithInt:16] forKey:kDefaultFontSize];
    [_values setObject:[NSNumber numberWithInt:13] forKey:kDefaultFixedSize];
    [_values setObject:[NSNumber numberWithInt:0] forKey:kMinimumFontSize];

    NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
                              dictionaryForKey:[self _defaultsKey]];
    if (saved)
        [_values addEntriesFromDictionary:saved];

    if (!sByIdentifier)
        sByIdentifier = [[NSMutableDictionary alloc] init];
    [sByIdentifier setObject:self forKey:(identifier ?: @"")];

    return self;
}

- (id)init
{
    return [self initWithIdentifier:nil];
}

- (void)dealloc
{
    [_identifier release];
    [_values release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }

- (NSString *)_defaultsKey
{
    return [NSString stringWithFormat:@"WebPreferences-%@", _identifier ?: @"standard"];
}

- (void)_set:(id)value forKey:(NSString *)key
{
    if ([[_values objectForKey:key] isEqual:value])
        return;
    [_values setObject:value forKey:key];
    if (_autosaves) {
        [[NSUserDefaults standardUserDefaults] setObject:_values forKey:[self _defaultsKey]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:WebPreferencesChangedNotification
                                                        object:self];
}

- (void)setAutosaves:(BOOL)flag
{
    _autosaves = flag;
    if (flag) {
        [[NSUserDefaults standardUserDefaults] setObject:_values forKey:[self _defaultsKey]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
- (BOOL)autosaves { return _autosaves; }

- (void)setJavaScriptEnabled:(BOOL)flag { [self _set:[NSNumber numberWithBool:flag] forKey:kJavaScriptEnabled]; }
- (BOOL)isJavaScriptEnabled { return [[_values objectForKey:kJavaScriptEnabled] boolValue]; }

- (void)setStandardFontFamily:(NSString *)f { [self _set:[[f copy] autorelease] forKey:kStandardFont]; }
- (NSString *)standardFontFamily { return [_values objectForKey:kStandardFont]; }
- (void)setSerifFontFamily:(NSString *)f { [self _set:[[f copy] autorelease] forKey:kSerifFont]; }
- (NSString *)serifFontFamily { return [_values objectForKey:kSerifFont]; }
- (void)setSansSerifFontFamily:(NSString *)f { [self _set:[[f copy] autorelease] forKey:kSansSerifFont]; }
- (NSString *)sansSerifFontFamily { return [_values objectForKey:kSansSerifFont]; }
- (void)setFixedFontFamily:(NSString *)f { [self _set:[[f copy] autorelease] forKey:kFixedFont]; }
- (NSString *)fixedFontFamily { return [_values objectForKey:kFixedFont]; }

- (void)setDefaultFontSize:(int)s { [self _set:[NSNumber numberWithInt:s] forKey:kDefaultFontSize]; }
- (int)defaultFontSize { return [[_values objectForKey:kDefaultFontSize] intValue]; }
- (void)setDefaultFixedFontSize:(int)s { [self _set:[NSNumber numberWithInt:s] forKey:kDefaultFixedSize]; }
- (int)defaultFixedFontSize { return [[_values objectForKey:kDefaultFixedSize] intValue]; }
- (void)setMinimumFontSize:(int)s { [self _set:[NSNumber numberWithInt:s] forKey:kMinimumFontSize]; }
- (int)minimumFontSize { return [[_values objectForKey:kMinimumFontSize] intValue]; }

- (void)setLoadsImagesAutomatically:(BOOL)flag { [self _set:[NSNumber numberWithBool:flag] forKey:kLoadsImages]; }
- (BOOL)loadsImagesAutomatically { return [[_values objectForKey:kLoadsImages] boolValue]; }

@end
