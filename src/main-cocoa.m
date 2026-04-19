/* File: main-cocoa.m */

/*
 * Experimental direct Cocoa z-term backend for the macOS app.
 *
 * The stable macOS target still ships the pty/curses wrapper. This backend
 * links the game core in-process and draws z-term cells directly in AppKit.
 */

#import <Cocoa/Cocoa.h>

#include "angband.h"

#include <pthread.h>
#include <string.h>
#include <unistd.h>

#define COCOA_COLS 80
#define COCOA_ROWS 24
#define COCOA_KEY_QUEUE 1024
#define COCOA_DEFAULT_WINDOW_WIDTH 1280.0
#define COCOA_DEFAULT_WINDOW_HEIGHT 760.0
#define COCOA_TERMINAL_MIN_WIDTH 700.0
#define COCOA_INSPECTOR_WIDTH 372.0
#define COCOA_INSPECTOR_MIN_WIDTH 300.0
#define COCOA_MESSAGE_LIMIT 300
#define COCOA_CTRL(c) ((c) & 0x1F)

extern int zangband_game_main(int argc, char **argv);

@protocol ZBDeathRestartPresenter <NSObject>
- (void)maybeShowDeathRestartOptions;
@end

cptr help_cocoa[] =
{
	"To use Cocoa, run the native macOS app target.",
	NULL
};

typedef struct cocoa_cell cocoa_cell;

struct cocoa_cell
{
	char c;
	byte a;
	bool dirty;
};

static term term_screen_cocoa;
static cocoa_cell screen_cells[COCOA_ROWS][COCOA_COLS];
static int cursor_x = 0;
static int cursor_y = 0;
static bool cursor_visible = TRUE;

static pthread_mutex_t screen_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t key_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t key_cond = PTHREAD_COND_INITIALIZER;
static int key_queue[COCOA_KEY_QUEUE];
static int key_head = 0;
static int key_tail = 0;
static bool redraw_queued = FALSE;

@class ZBCocoaTermView;
@class ZBCocoaInspectorView;
static ZBCocoaTermView *cocoa_view = nil;
static ZBCocoaInspectorView *cocoa_inspector = nil;
static id<ZBDeathRestartPresenter> cocoa_app_delegate = nil;
static NSMutableArray<NSString *> *message_history = nil;
static bool message_row_dirty = FALSE;

static void cocoa_queue_redraw(void);
static void cocoa_enqueue_key(int key);

static NSString *ZBTrim(NSString *string)
{
	if (!string) return @"";
	return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZBStringFromBytes(const char *bytes, NSUInteger length)
{
	if (!bytes || !length) return @"";

	NSUInteger actualLength = 0;
	while (actualLength < length && bytes[actualLength] != '\0') actualLength++;

	NSString *string = [[NSString alloc] initWithBytes:bytes
	                                            length:actualLength
	                                          encoding:NSASCIIStringEncoding];
	if (!string)
	{
		string = [[NSString alloc] initWithBytes:bytes
		                                  length:actualLength
		                                encoding:NSISOLatin1StringEncoding] ?: @"";
	}

	return ZBTrim(string);
}

static void cocoa_capture_message_from_screen(void)
{
	pthread_mutex_lock(&screen_lock);
	if (!message_row_dirty)
	{
		pthread_mutex_unlock(&screen_lock);
		return;
	}

	message_row_dirty = FALSE;

	char line[COCOA_COLS + 1];
	for (int x = 0; x < COCOA_COLS; x++)
	{
		char c = screen_cells[0][x].c;
		line[x] = c ? c : ' ';
	}
	line[COCOA_COLS] = '\0';

	NSString *messageLine = ZBTrim(ZBStringFromBytes(line, COCOA_COLS));
	if (messageLine.length)
	{
		if (!message_history) message_history = [NSMutableArray arrayWithCapacity:COCOA_MESSAGE_LIMIT];
		if (![message_history.lastObject isEqualToString:messageLine])
		{
			[message_history addObject:messageLine];
			while (message_history.count > COCOA_MESSAGE_LIMIT)
			{
				[message_history removeObjectAtIndex:0];
			}
		}
	}

	pthread_mutex_unlock(&screen_lock);
}

static NSString *ZBKeyString(int key)
{
	unichar ch = (unichar)key;
	return [NSString stringWithCharacters:&ch length:1];
}

static NSString *ZBRunSequence(int direction)
{
	return [NSString stringWithFormat:@"%@%@", ZBKeyString('.'), ZBKeyString(direction)];
}

static NSString *ZBRandomCharacterName(void)
{
	static NSArray<NSString *> *names = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		names = @[
			@"Aelar", @"Alden", @"Anwen", @"Arlen", @"Ashwyn", @"Bastian",
			@"Briar", @"Calder", @"Cassia", @"Corwin", @"Darian", @"Delwyn",
			@"Elara", @"Elowen", @"Emrys", @"Fenric", @"Galen", @"Garrick",
			@"Halden", @"Ilyra", @"Isolde", @"Jareth", @"Kael", @"Kestrel",
			@"Liora", @"Lucan", @"Maelis", @"Mira", @"Nerys", @"Nyx",
			@"Orin", @"Perrin", @"Quill", @"Rowan", @"Sable", @"Selene",
			@"Seren", @"Sylas", @"Tamsin", @"Thorne", @"Varek", @"Vesper",
			@"Wren", @"Ysara", @"Zephyr"
		];
	});

	return names[arc4random_uniform((uint32_t)names.count)];
}

static NSArray<NSURL *> *ZBApplicationSupportRoots(void)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
	if (!base) return @[];

	return @[
		[base URLByAppendingPathComponent:@"ZangbandNative" isDirectory:YES],
		[base URLByAppendingPathComponent:@"Zangband" isDirectory:YES]
	];
}

static NSString *ZBReadableDate(NSDate *date)
{
	if (!date) return @"Unknown";

	static NSDateFormatter *formatter = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		formatter = [[NSDateFormatter alloc] init];
		formatter.dateStyle = NSDateFormatterMediumStyle;
		formatter.timeStyle = NSDateFormatterShortStyle;
	});

	return [formatter stringFromDate:date];
}

static NSArray<NSString *> *cocoa_snapshot_rows(void)
{
	NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:COCOA_ROWS];

	pthread_mutex_lock(&screen_lock);
	for (int y = 0; y < COCOA_ROWS; y++)
	{
		char line[COCOA_COLS + 1];
		for (int x = 0; x < COCOA_COLS; x++)
		{
			char c = screen_cells[y][x].c;
			line[x] = c ? c : ' ';
		}
		line[COCOA_COLS] = '\0';
		[rows addObject:ZBTrim(ZBStringFromBytes(line, COCOA_COLS))];
	}
	pthread_mutex_unlock(&screen_lock);

	return rows;
}

static NSString *ZBJoinedVisibleScreen(void)
{
	NSArray<NSString *> *rows = cocoa_snapshot_rows();
	NSMutableString *screen = [NSMutableString string];

	for (NSString *row in rows)
	{
		if (row.length) [screen appendFormat:@"%@\n", row];
	}

	return screen.length ? screen : @"No visible game text yet.";
}

static NSString *ZBFirstLineContaining(NSArray<NSString *> *rows, NSArray<NSString *> *needles)
{
	for (NSString *row in rows)
	{
		for (NSString *needle in needles)
		{
			if ([row rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
			{
				return row;
			}
		}
	}

	return @"Unknown";
}

static NSString *ZBValueAfterLabel(NSArray<NSString *> *rows, NSArray<NSString *> *labels)
{
	for (NSString *row in rows)
	{
		for (NSString *label in labels)
		{
			NSRange range = [row rangeOfString:label options:NSCaseInsensitiveSearch];
			if (range.location == NSNotFound) continue;

			NSUInteger start = NSMaxRange(range);
			while (start < row.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[row characterAtIndex:start]]) start++;
			if (start < row.length && [row characterAtIndex:start] == ':') start++;

			NSString *value = ZBTrim([row substringFromIndex:start]);
			if (value.length) return value;
		}
	}

	return @"Unknown";
}

static NSString *ZBActiveCharacterSummary(void)
{
	NSArray<NSString *> *rows = cocoa_snapshot_rows();
	NSString *name = player_name[0] ? ZBStringFromBytes(player_name, sizeof(player_name)) : ZBValueAfterLabel(rows, @[@"Name"]);
	NSString *level = (p_ptr && p_ptr->lev > 0) ? [NSString stringWithFormat:@"%d", p_ptr->lev] : ZBValueAfterLabel(rows, @[@"LEVEL", @"Level"]);
	NSString *depth = @"Unknown";
	NSString *death = @"Alive / in progress";

	if (p_ptr)
	{
		if (p_ptr->depth > 0)
		{
			depth = [NSString stringWithFormat:@"%d", p_ptr->depth];
		}
		else if (p_ptr->state.playing || character_dungeon)
		{
			depth = @"Town / wilderness";
		}

		if (p_ptr->state.is_dead)
		{
			NSString *cause = ZBStringFromBytes(p_ptr->state.died_from, sizeof(p_ptr->state.died_from));
			death = cause.length ? [NSString stringWithFormat:@"Dead: %@", cause] : @"Dead";
		}
		else if (!p_ptr->state.playing && !character_dungeon)
		{
			death = @"Not currently in a run";
		}
	}

	if ([depth isEqualToString:@"Unknown"])
	{
		depth = ZBValueAfterLabel(rows, @[@"DEPTH", @"Depth", @"Dungeon"]);
	}

	for (NSString *row in rows)
	{
		if ([row rangeOfString:@"killed by" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		    [row rangeOfString:@"died" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		    [row rangeOfString:@"dead" options:NSCaseInsensitiveSearch].location != NSNotFound)
		{
			if (![death hasPrefix:@"Dead"]) death = @"Dead / post-run screen";
			break;
		}
	}

	if ([name isEqualToString:@"Unknown"])
	{
		name = ZBFirstLineContaining(rows, @[@"Name"]);
	}

	return [NSString stringWithFormat:@"Active character: %@\nLevel: %@\nDepth: %@\nStatus: %@",
	        name, level, depth, death];
}

static NSString *ZBFileSizeString(unsigned long long bytes)
{
	NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
	formatter.countStyle = NSByteCountFormatterCountStyleFile;
	return [formatter stringFromByteCount:(long long)bytes];
}

static NSString *ZBSaveManagerReport(void)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSMutableString *report = [NSMutableString stringWithFormat:@"Save Manager\n============\n\n%@\n\n",
	                           ZBActiveCharacterSummary()];
	NSDate *latestDate = nil;
	NSMutableArray<NSString *> *saveLines = [NSMutableArray array];

	for (NSURL *root in ZBApplicationSupportRoots())
	{
		NSURL *saveURL = [[root URLByAppendingPathComponent:@"lib" isDirectory:YES] URLByAppendingPathComponent:@"save" isDirectory:YES];
		NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:saveURL
		                             includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey, NSURLFileSizeKey]
		                                                options:NSDirectoryEnumerationSkipsHiddenFiles
		                                                  error:nil] ?: @[];

		for (NSURL *fileURL in files)
		{
			if ([fileURL.lastPathComponent isEqualToString:@"makefile.zb"]) continue;

			NSNumber *isRegular = nil;
			[fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
			if (!isRegular.boolValue) continue;

			NSDate *modified = nil;
			NSNumber *size = nil;
			[fileURL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
			[fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
			if (!latestDate || [modified compare:latestDate] == NSOrderedDescending) latestDate = modified;

			NSString *appName = [root.lastPathComponent isEqualToString:@"ZangbandNative"] ? @"Native" : @"Wrapper";
			[saveLines addObject:[NSString stringWithFormat:@"%@ save: %@\n  Last played: %@\n  Size: %@\n  Path: %@",
			                      appName,
			                      fileURL.lastPathComponent,
			                      ZBReadableDate(modified),
			                      ZBFileSizeString(size.unsignedLongLongValue),
			                      fileURL.path]];
		}
	}

	[report appendFormat:@"Last played time: %@\n\n", latestDate ? ZBReadableDate(latestDate) : @"No save files found"];

	if (saveLines.count)
	{
		[report appendString:@"Known Saves\n-----------\n\n"];
		[saveLines sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
		[report appendString:[saveLines componentsJoinedByString:@"\n\n"]];
	}
	else
	{
		[report appendString:@"No save files were found in the native or wrapper app support folders."];
	}

	[report appendString:@"\n\nNote: Zangband save files are legacy binary files. The native manager shows exact file metadata and live character details from the running screen; historical depth/level/death details come from the morgue scores when a run has ended."];

	return report;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ZBMorgueEntries(void)
{
	NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
	NSFileManager *fm = NSFileManager.defaultManager;

	for (NSURL *root in ZBApplicationSupportRoots())
	{
		NSURL *scoresURL = [[[root URLByAppendingPathComponent:@"lib" isDirectory:YES] URLByAppendingPathComponent:@"apex" isDirectory:YES] URLByAppendingPathComponent:@"scores.raw"];
		NSData *data = [NSData dataWithContentsOfURL:scoresURL];
		if (data.length < sizeof(high_score)) continue;

		const high_score *scores = (const high_score *)data.bytes;
		NSUInteger count = data.length / sizeof(high_score);
		NSString *source = [root.lastPathComponent isEqualToString:@"ZangbandNative"] ? @"Native" : @"Wrapper";

		for (NSUInteger i = 0; i < count; i++)
		{
			NSString *who = ZBStringFromBytes(scores[i].who, sizeof(scores[i].who));
			NSString *how = ZBStringFromBytes(scores[i].how, sizeof(scores[i].how));
			if (!who.length || !how.length) continue;

			[entries addObject:@{
				@"source": source,
				@"who": who,
				@"how": how,
				@"score": ZBStringFromBytes(scores[i].pts, sizeof(scores[i].pts)),
				@"turns": ZBStringFromBytes(scores[i].turns, sizeof(scores[i].turns)),
				@"day": ZBStringFromBytes(scores[i].day, sizeof(scores[i].day)),
				@"level": ZBStringFromBytes(scores[i].cur_lev, sizeof(scores[i].cur_lev)),
				@"depth": ZBStringFromBytes(scores[i].cur_dun, sizeof(scores[i].cur_dun)),
				@"maxLevel": ZBStringFromBytes(scores[i].max_lev, sizeof(scores[i].max_lev)),
				@"maxDepth": ZBStringFromBytes(scores[i].max_dun, sizeof(scores[i].max_dun))
			}];
		}
	}

	[entries sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, NSString *> *a, NSDictionary<NSString *, NSString *> *b) {
		NSInteger left = a[@"score"].integerValue;
		NSInteger right = b[@"score"].integerValue;
		if (left == right) return [a[@"who"] localizedCaseInsensitiveCompare:b[@"who"]];
		return (left > right) ? NSOrderedAscending : NSOrderedDescending;
	}];

	return entries;
}

static NSString *ZBMorgueReport(void)
{
	NSArray<NSDictionary<NSString *, NSString *> *> *entries = ZBMorgueEntries();
	NSMutableString *report = [NSMutableString stringWithString:@"Morgue Gallery\n==============\n\n"];

	if (!entries.count)
	{
		[report appendString:@"No dead or retired runs were found in scores.raw yet.\n"];
		return report;
	}

	for (NSDictionary<NSString *, NSString *> *entry in entries)
	{
		[report appendFormat:@"%@ - %@ points\n", entry[@"who"], entry[@"score"]];
		[report appendFormat:@"  Cause: %@\n", entry[@"how"]];
		[report appendFormat:@"  Level/depth: %@ / %@ (max %@ / %@)\n",
		 entry[@"level"], entry[@"depth"], entry[@"maxLevel"], entry[@"maxDepth"]];
		[report appendFormat:@"  Turns: %@    Date: %@    Source: %@\n\n",
		 entry[@"turns"], entry[@"day"], entry[@"source"]];
	}

	return report;
}

static NSString *ZBObjectName(const object_type *o_ptr)
{
	if (!o_ptr || !o_ptr->k_idx) return nil;

	char name[256];
	object_desc(name, o_ptr, TRUE, 3, sizeof(name));
	fmt_clean(name);
	return ZBStringFromBytes(name, strlen(name));
}

static NSString *ZBInventoryReport(void)
{
	if (!p_ptr || (!p_ptr->state.playing && !character_dungeon)) return @"No active inventory.";

	NSMutableString *report = [NSMutableString stringWithString:@"Inventory\n---------\n"];
	int index = 0;
	object_type *o_ptr = NULL;

	OBJ_ITT_START(p_ptr->inventory, o_ptr)
	{
		NSString *name = ZBObjectName(o_ptr) ?: @"Unknown item";
		[report appendFormat:@"%c) %@\n", I2A(index), name];
		index++;
	}
	OBJ_ITT_END;

	if (!index) [report appendString:@"Pack is empty."];
	return report;
}

static NSString *ZBEquipmentReport(void)
{
	if (!p_ptr || (!p_ptr->state.playing && !character_dungeon)) return @"No active equipment.";

	static const char *slotNames[EQUIP_MAX] = {
		"Wield", "Bow", "Left hand", "Right hand", "Neck", "Light",
		"Body", "Outer", "Arm", "Head", "Hands", "Feet"
	};

	NSMutableString *report = [NSMutableString stringWithString:@"Equipment\n---------\n"];

	for (int i = 0; i < EQUIP_MAX; i++)
	{
		NSString *name = ZBObjectName(&p_ptr->equipment[i]) ?: @"(empty)";
		[report appendFormat:@"%c) %-10s %@\n", I2A(i), slotNames[i], name];
	}

	return report;
}

@interface ZBCocoaTermView : NSView <NSMenuItemValidation>
@property (nonatomic, assign, getter=isTileMode) BOOL tileMode;
- (void)enqueueKey:(int)key;
@end

@implementation ZBCocoaTermView {
	NSFont *_font;
	CGFloat _cellWidth;
	CGFloat _cellHeight;
	CGFloat _baselineOffset;
	CGFloat _contentX;
	CGFloat _contentY;
	NSArray<NSColor *> *_colors;
	NSArray<NSString *> *_glyphs;
	NSArray<NSDictionary<NSAttributedStringKey, id> *> *_textAttributes;
	BOOL _tileMode;
}

- (instancetype)initWithFrame:(NSRect)frame {
	self = [super initWithFrame:frame];
	if (!self) return nil;

	_font = [NSFont fontWithName:@"Menlo-Regular" size:16.0] ?: [NSFont monospacedSystemFontOfSize:16.0 weight:NSFontWeightRegular];

	NSDictionary *attrs = @{ NSFontAttributeName: _font };
	_cellWidth = ceil([@"W" sizeWithAttributes:attrs].width);
	_cellHeight = ceil(_font.ascender - _font.descender + _font.leading) + 3.0;
	_baselineOffset = floor((_cellHeight - (_font.ascender - _font.descender)) / 2.0);

	_colors = @[
		[NSColor colorWithCalibratedWhite:0.00 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.82 green:0.85 blue:0.80 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.48 green:0.54 blue:0.50 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.72 green:0.55 blue:0.30 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.74 green:0.24 blue:0.22 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.24 green:0.66 blue:0.36 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.40 green:0.52 blue:0.86 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.55 green:0.42 blue:0.28 alpha:1.0],
		[NSColor colorWithCalibratedWhite:0.24 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.68 green:0.72 blue:0.68 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.58 green:0.42 blue:0.68 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.76 green:0.68 blue:0.34 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.92 green:0.34 blue:0.30 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.36 green:0.78 blue:0.42 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.40 green:0.72 blue:0.82 alpha:1.0],
		[NSColor colorWithCalibratedRed:0.70 green:0.56 blue:0.38 alpha:1.0]
	];

	NSMutableArray<NSString *> *glyphs = [NSMutableArray arrayWithCapacity:128];
	for (NSUInteger i = 0; i < 128; i++)
	{
		unichar ch = (unichar)i;
		[glyphs addObject:[NSString stringWithCharacters:&ch length:1]];
	}
	_glyphs = glyphs;

	NSMutableArray<NSDictionary<NSAttributedStringKey, id> *> *textAttributes = [NSMutableArray arrayWithCapacity:_colors.count];
	for (NSColor *color in _colors)
	{
		[textAttributes addObject:@{
			NSFontAttributeName: _font,
			NSForegroundColorAttributeName: color
		}];
	}
	_textAttributes = textAttributes;

	return self;
}

- (BOOL)acceptsFirstResponder {
	return YES;
}

- (BOOL)isFlipped {
	return YES;
}

- (void)viewDidMoveToWindow {
	[super viewDidMoveToWindow];
	[self.window makeFirstResponder:self];
}

- (void)setFrameSize:(NSSize)newSize {
	[super setFrameSize:newSize];
	[self setNeedsDisplay:YES];
}

- (void)recalculateOrigin {
	CGFloat width = (CGFloat)COCOA_COLS * _cellWidth;
	CGFloat height = (CGFloat)COCOA_ROWS * _cellHeight;
	_contentX = floor(MAX(18.0, (NSWidth(self.bounds) - width) / 2.0));
	_contentY = floor(MAX(18.0, (NSHeight(self.bounds) - height) / 2.0));
}

- (NSColor *)colorForAttr:(byte)a {
	return _colors[MIN((NSUInteger)(a % 16), _colors.count - 1)];
}

- (NSColor *)tileColorForCharacter:(char)c attr:(byte)a {
	(void)a;

	switch (c)
	{
		case '.': return [NSColor colorWithCalibratedRed:0.12 green:0.13 blue:0.12 alpha:1.0];
		case ',': return [NSColor colorWithCalibratedRed:0.10 green:0.18 blue:0.10 alpha:1.0];
		case ':': return [NSColor colorWithCalibratedRed:0.18 green:0.16 blue:0.12 alpha:1.0];
		case ';': return [NSColor colorWithCalibratedRed:0.10 green:0.18 blue:0.15 alpha:1.0];
		case '#': return [NSColor colorWithCalibratedRed:0.23 green:0.24 blue:0.23 alpha:1.0];
		case '%': return [NSColor colorWithCalibratedRed:0.06 green:0.23 blue:0.09 alpha:1.0];
		case '~': return [NSColor colorWithCalibratedRed:0.06 green:0.16 blue:0.28 alpha:1.0];
		case '+': return [NSColor colorWithCalibratedRed:0.30 green:0.20 blue:0.11 alpha:1.0];
		case '<':
		case '>': return [NSColor colorWithCalibratedRed:0.20 green:0.16 blue:0.30 alpha:1.0];
		case '*': return [NSColor colorWithCalibratedRed:0.36 green:0.30 blue:0.08 alpha:1.0];
		case '$': return [NSColor colorWithCalibratedRed:0.27 green:0.24 blue:0.07 alpha:1.0];
		default: break;
	}

	if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
	{
		return [NSColor colorWithCalibratedRed:0.22 green:0.08 blue:0.08 alpha:1.0];
	}

	return nil;
}

- (void)setTileMode:(BOOL)tileMode {
	if (_tileMode == tileMode) return;
	_tileMode = tileMode;
	[self setNeedsDisplay:YES];
}

- (BOOL)isTileMode {
	return _tileMode;
}

- (IBAction)toggleTileMode:(id)sender {
	(void)sender;
	self.tileMode = !self.tileMode;
}

- (void)drawRect:(NSRect)dirtyRect {
	(void)dirtyRect;
	[self recalculateOrigin];

	[[NSColor colorWithCalibratedRed:0.025 green:0.028 blue:0.026 alpha:1.0] setFill];
	NSRectFill(self.bounds);

	NSRect terminalRect = NSMakeRect(_contentX, _contentY, (CGFloat)COCOA_COLS * _cellWidth, (CGFloat)COCOA_ROWS * _cellHeight);
	[[NSColor blackColor] setFill];
	NSRectFill(terminalRect);

	pthread_mutex_lock(&screen_lock);
	if (_tileMode)
	{
		for (int y = 0; y < COCOA_ROWS; y++)
		{
			for (int x = 0; x < COCOA_COLS; x++)
			{
				char c = screen_cells[y][x].c ? screen_cells[y][x].c : ' ';
				NSColor *tileColor = [self tileColorForCharacter:c attr:screen_cells[y][x].a];
				if (!tileColor) continue;

				NSRect cellRect = NSMakeRect(_contentX + (CGFloat)x * _cellWidth,
				                             _contentY + (CGFloat)y * _cellHeight,
				                             _cellWidth,
				                             _cellHeight);
				[tileColor setFill];
				NSRectFill(NSInsetRect(cellRect, 1.0, 1.0));
			}
		}
	}

	for (int y = 0; y < COCOA_ROWS; y++)
	{
		for (int x = 0; x < COCOA_COLS; x++)
		{
			unsigned char c = (unsigned char)(screen_cells[y][x].c ? screen_cells[y][x].c : ' ');
			screen_cells[y][x].dirty = FALSE;
			if (c == ' ') continue;

			byte attr = screen_cells[y][x].a % 16;
			NSString *glyph = (c < _glyphs.count) ? _glyphs[c] : @"?";
			NSDictionary<NSAttributedStringKey, id> *attrs = _textAttributes[MIN((NSUInteger)attr, _textAttributes.count - 1)];
			[glyph drawAtPoint:NSMakePoint(_contentX + (CGFloat)x * _cellWidth,
			                                _contentY + (CGFloat)y * _cellHeight + _baselineOffset)
			     withAttributes:attrs];
		}
	}

	if (cursor_visible)
	{
		NSRect cursorRect = NSMakeRect(_contentX + (CGFloat)cursor_x * _cellWidth,
		                               _contentY + (CGFloat)cursor_y * _cellHeight + _cellHeight - 2.0,
		                               _cellWidth,
		                               2.0);
		[[NSColor colorWithCalibratedRed:0.82 green:0.85 blue:0.80 alpha:0.85] setFill];
		NSRectFill(cursorRect);
	}
	pthread_mutex_unlock(&screen_lock);
}

- (void)enqueueKey:(int)key {
	cocoa_enqueue_key(key);
}

- (BOOL)eventShouldRun:(NSEvent *)event {
	NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
	return ((flags & NSEventModifierFlagShift) &&
	        !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)));
}

- (void)enqueueDirectionKey:(int)direction fromEvent:(NSEvent *)event {
	if ([self eventShouldRun:event]) [self enqueueKey:'.'];
	[self enqueueKey:direction];
}

- (void)enqueueText:(NSString *)text {
	for (NSUInteger i = 0; i < text.length; i++)
	{
		unichar ch = [text characterAtIndex:i];
		if (ch == '\n')
		{
			[self enqueueKey:'\r'];
		}
		else if (ch == '\t')
		{
			[self enqueueKey:'\t'];
		}
		else if (ch >= 0x20 && ch < 0x7F)
		{
			[self enqueueKey:(int)ch];
		}
	}
}

- (BOOL)enqueueControlKeyFromEvent:(NSEvent *)event {
	NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
	if (!(flags & NSEventModifierFlagControl)) return NO;
	if (flags & NSEventModifierFlagCommand) return NO;

	NSString *chars = event.charactersIgnoringModifiers ?: @"";
	if (chars.length != 1) return NO;

	unichar ch = [chars characterAtIndex:0];
	if (ch >= 'a' && ch <= 'z')
	{
		[self enqueueKey:COCOA_CTRL(ch - ('a' - 'A'))];
		return YES;
	}
	if (ch >= '@' && ch <= '_')
	{
		[self enqueueKey:COCOA_CTRL(ch)];
		return YES;
	}

	return NO;
}

- (BOOL)enqueueKeypadKeyFromEvent:(NSEvent *)event {
	if (!(event.modifierFlags & NSEventModifierFlagNumericPad)) return NO;

	switch (event.keyCode)
	{
		case 82: [self enqueueKey:'0']; return YES;
		case 83: [self enqueueDirectionKey:'1' fromEvent:event]; return YES;
		case 84: [self enqueueDirectionKey:'2' fromEvent:event]; return YES;
		case 85: [self enqueueDirectionKey:'3' fromEvent:event]; return YES;
		case 86: [self enqueueDirectionKey:'4' fromEvent:event]; return YES;
		case 87: [self enqueueKey:'5']; return YES;
		case 88: [self enqueueDirectionKey:'6' fromEvent:event]; return YES;
		case 89: [self enqueueDirectionKey:'7' fromEvent:event]; return YES;
		case 91: [self enqueueDirectionKey:'8' fromEvent:event]; return YES;
		case 92: [self enqueueDirectionKey:'9' fromEvent:event]; return YES;
		case 65: [self enqueueKey:'.']; return YES;
		case 67: [self enqueueKey:'*']; return YES;
		case 69: [self enqueueKey:'+']; return YES;
		case 75: [self enqueueKey:'/']; return YES;
		case 76: [self enqueueKey:'\r']; return YES;
		case 78: [self enqueueKey:'-']; return YES;
		default: return NO;
	}
}

- (void)paste:(id)sender {
	(void)sender;
	NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
	if (text.length) [self enqueueText:text];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
	if (menuItem.action == @selector(paste:))
	{
		return [NSPasteboard.generalPasteboard canReadItemWithDataConformingToTypes:@[NSPasteboardTypeString]];
	}
	if (menuItem.action == @selector(toggleTileMode:))
	{
		menuItem.state = self.tileMode ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}

	return YES;
}

- (void)keyDown:(NSEvent *)event {
	if ([self enqueueControlKeyFromEvent:event]) return;
	if ([self enqueueKeypadKeyFromEvent:event]) return;

	NSString *chars = event.charactersIgnoringModifiers ?: @"";
	unichar key = chars.length ? [chars characterAtIndex:0] : 0;

	switch (key)
	{
		case NSUpArrowFunctionKey:    [self enqueueDirectionKey:'8' fromEvent:event]; return;
		case NSDownArrowFunctionKey:  [self enqueueDirectionKey:'2' fromEvent:event]; return;
		case NSRightArrowFunctionKey: [self enqueueDirectionKey:'6' fromEvent:event]; return;
		case NSLeftArrowFunctionKey:  [self enqueueDirectionKey:'4' fromEvent:event]; return;
		case NSHomeFunctionKey:       [self enqueueDirectionKey:'7' fromEvent:event]; return;
		case NSEndFunctionKey:        [self enqueueDirectionKey:'1' fromEvent:event]; return;
		case NSPageUpFunctionKey:     [self enqueueDirectionKey:'9' fromEvent:event]; return;
		case NSPageDownFunctionKey:   [self enqueueDirectionKey:'3' fromEvent:event]; return;
		case NSDeleteCharacter:
		case NSBackspaceCharacter:    [self enqueueKey:'\010']; return;
		case NSDeleteFunctionKey:     [self enqueueKey:0x7F]; return;
		case 0x1B:                    [self enqueueKey:ESCAPE]; return;
		case '\r':
		case '\n':                    [self enqueueKey:'\r']; return;
		case '\t':                    [self enqueueKey:'\t']; return;
		default: break;
	}

	NSString *text = event.characters ?: chars;
	[self enqueueText:text];
}

@end

@interface ZBCocoaInspectorView : NSView
- (void)refreshFromGame;
@end

@implementation ZBCocoaInspectorView {
	NSBox *_inventoryBox;
	NSBox *_equipmentBox;
	NSBox *_contextBox;
	NSTabView *_contextTabs;
	NSTextView *_messagesView;
	NSTextView *_inventoryView;
	NSTextView *_equipmentView;
	NSTextView *_recallView;
}

- (instancetype)initWithFrame:(NSRect)frame {
	self = [super initWithFrame:frame];
	if (!self) return nil;

	self.wantsLayer = YES;
	self.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.055 green:0.060 blue:0.056 alpha:1.0].CGColor;

	_inventoryBox = [self addBoxWithTitle:@"Inventory"];
	_inventoryView = [self addTextViewToBox:_inventoryBox];

	_equipmentBox = [self addBoxWithTitle:@"Equipment"];
	_equipmentView = [self addTextViewToBox:_equipmentBox];

	_contextBox = [self addBoxWithTitle:@"Run Context"];
	_contextTabs = [[NSTabView alloc] initWithFrame:_contextBox.contentView.bounds];
	_contextTabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[_contextBox.contentView addSubview:_contextTabs];

	_messagesView = [self addTextTab:@"Messages" toTabView:_contextTabs];
	_recallView = [self addTextTab:@"Recall" toTabView:_contextTabs];

	[self refreshFromGame];
	return self;
}

- (BOOL)isFlipped {
	return YES;
}

- (NSBox *)addBoxWithTitle:(NSString *)title {
	NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
	box.title = title;
	box.titleFont = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
	box.borderColor = [NSColor colorWithCalibratedRed:0.16 green:0.17 blue:0.16 alpha:1.0];
	box.fillColor = [NSColor colorWithCalibratedRed:0.035 green:0.038 blue:0.035 alpha:1.0];
	box.boxType = NSBoxCustom;
	[self addSubview:box];
	return box;
}

- (NSTextView *)textViewInScrollView:(NSScrollView **)scrollViewOut {
	NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scrollView.borderType = NSNoBorder;
	scrollView.hasVerticalScroller = YES;
	scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSTextView *textView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
	textView.editable = NO;
	textView.selectable = YES;
	textView.drawsBackground = YES;
	textView.backgroundColor = [NSColor colorWithCalibratedRed:0.035 green:0.038 blue:0.035 alpha:1.0];
	textView.textColor = [NSColor colorWithCalibratedRed:0.78 green:0.82 blue:0.76 alpha:1.0];
	textView.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
	textView.textContainerInset = NSMakeSize(10.0, 10.0);
	textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scrollView.documentView = textView;

	if (scrollViewOut) *scrollViewOut = scrollView;
	return textView;
}

- (NSTextView *)addTextViewToBox:(NSBox *)box {
	NSScrollView *scrollView = nil;
	NSTextView *textView = [self textViewInScrollView:&scrollView];
	scrollView.frame = box.contentView.bounds;
	[box.contentView addSubview:scrollView];
	return textView;
}

- (NSTextView *)addTextTab:(NSString *)label toTabView:(NSTabView *)tabView {
	NSScrollView *scrollView = nil;
	NSTextView *textView = [self textViewInScrollView:&scrollView];
	scrollView.frame = tabView.bounds;

	NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:label];
	item.label = label;
	item.view = scrollView;
	[tabView addTabViewItem:item];

	return textView;
}

- (void)layout {
	[super layout];

	CGFloat padding = 8.0;
	CGFloat gap = 8.0;
	CGFloat width = NSWidth(self.bounds) - padding * 2.0;
	CGFloat available = NSHeight(self.bounds) - padding * 2.0 - gap * 2.0;
	if (available <= 0.0) return;

	CGFloat inventoryHeight = floor(MIN(220.0, MAX(130.0, available * 0.28)));
	CGFloat equipmentHeight = floor(MIN(250.0, MAX(160.0, available * 0.34)));
	CGFloat contextHeight = available - inventoryHeight - equipmentHeight;

	if (contextHeight < 170.0)
	{
		CGFloat deficit = 170.0 - contextHeight;
		CGFloat inventoryShrink = MIN(deficit / 2.0, MAX(0.0, inventoryHeight - 105.0));
		inventoryHeight -= inventoryShrink;
		deficit -= inventoryShrink;
		CGFloat equipmentShrink = MIN(deficit, MAX(0.0, equipmentHeight - 125.0));
		equipmentHeight -= equipmentShrink;
		contextHeight = available - inventoryHeight - equipmentHeight;
	}

	CGFloat y = padding;
	_inventoryBox.frame = NSMakeRect(padding, y, width, inventoryHeight);
	y += inventoryHeight + gap;
	_equipmentBox.frame = NSMakeRect(padding, y, width, equipmentHeight);
	y += equipmentHeight + gap;
	_contextBox.frame = NSMakeRect(padding, y, width, MAX(0.0, contextHeight));

	for (NSBox *box in @[_inventoryBox, _equipmentBox])
	{
		NSView *child = box.contentView.subviews.firstObject;
		child.frame = box.contentView.bounds;
	}
	_contextTabs.frame = _contextBox.contentView.bounds;
}

- (NSString *)messageHistoryText {
	NSArray<NSString *> *history = nil;

	pthread_mutex_lock(&screen_lock);
	history = [message_history copy] ?: @[];
	pthread_mutex_unlock(&screen_lock);

	if (!history.count) return @"No messages captured yet.";

	NSMutableArray<NSString *> *newestFirst = [NSMutableArray arrayWithCapacity:history.count];
	for (NSString *message in [history reverseObjectEnumerator])
	{
		[newestFirst addObject:message];
	}

	return [newestFirst componentsJoinedByString:@"\n"];
}

- (NSString *)screenSectionWithNeedles:(NSArray<NSString *> *)needles emptyTitle:(NSString *)emptyTitle {
	NSArray<NSString *> *rows = cocoa_snapshot_rows();
	NSMutableArray<NSString *> *matches = [NSMutableArray array];

	for (NSString *row in rows)
	{
		if (!row.length) continue;
		for (NSString *needle in needles)
		{
			if ([row rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
			{
				[matches addObject:row];
				break;
			}
		}
	}

	if (matches.count) return [matches componentsJoinedByString:@"\n"];

	return emptyTitle;
}

- (void)refreshFromGame {
	if (!NSThread.isMainThread)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshFromGame];
		});
		return;
	}

	_messagesView.string = [self messageHistoryText];
	_inventoryView.string = ZBInventoryReport();
	_equipmentView.string = ZBEquipmentReport();
	_recallView.string = [self screenSectionWithNeedles:@[@"Recall", @"This monster", @"Kills", @"Speed", @"Armor", @"Experience"]
	                                          emptyTitle:@"No monster recall is visible yet."];
	[_messagesView setSelectedRange:NSMakeRange(0, 0)];
	[_messagesView scrollRangeToVisible:NSMakeRange(0, 0)];
}

@end

static void cocoa_enqueue_key(int key)
{
	if (!key) return;

	pthread_mutex_lock(&key_lock);
	int next = (key_head + 1) % COCOA_KEY_QUEUE;
	if (next != key_tail)
	{
		key_queue[key_head] = key;
		key_head = next;
		pthread_cond_signal(&key_cond);
	}
	pthread_mutex_unlock(&key_lock);
}

static void cocoa_queue_redraw(void)
{
	pthread_mutex_lock(&screen_lock);
	if (redraw_queued)
	{
		pthread_mutex_unlock(&screen_lock);
		return;
	}
	redraw_queued = TRUE;
	pthread_mutex_unlock(&screen_lock);

	dispatch_async(dispatch_get_main_queue(), ^{
		pthread_mutex_lock(&screen_lock);
		redraw_queued = FALSE;
		pthread_mutex_unlock(&screen_lock);
		[cocoa_view setNeedsDisplay:YES];
		[cocoa_inspector refreshFromGame];
		[cocoa_app_delegate maybeShowDeathRestartOptions];
	});
}

static int cocoa_pop_key(bool wait)
{
	int key = -1;

	pthread_mutex_lock(&key_lock);
	while (wait && key_head == key_tail)
	{
		pthread_cond_wait(&key_cond, &key_lock);
	}

	if (key_head != key_tail)
	{
		key = key_queue[key_tail];
		key_tail = (key_tail + 1) % COCOA_KEY_QUEUE;
	}
	pthread_mutex_unlock(&key_lock);

	return key;
}

static errr Term_curs_cocoa(int x, int y)
{
	pthread_mutex_lock(&screen_lock);
	cursor_x = MIN(MAX(x, 0), COCOA_COLS - 1);
	cursor_y = MIN(MAX(y, 0), COCOA_ROWS - 1);
	pthread_mutex_unlock(&screen_lock);
	cocoa_queue_redraw();
	return 0;
}

static errr Term_wipe_cocoa(int x, int y, int n)
{
	if (y < 0 || y >= COCOA_ROWS) return 0;
	if (x < 0) { n += x; x = 0; }
	if (x + n > COCOA_COLS) n = COCOA_COLS - x;
	if (n <= 0) return 0;

	pthread_mutex_lock(&screen_lock);
	for (int i = 0; i < n; i++)
	{
		screen_cells[y][x + i].c = ' ';
		screen_cells[y][x + i].a = TERM_DARK;
		screen_cells[y][x + i].dirty = TRUE;
	}
	if (y == 0) message_row_dirty = TRUE;
	pthread_mutex_unlock(&screen_lock);
	cocoa_queue_redraw();
	return 0;
}

static errr Term_text_cocoa(int x, int y, int n, byte a, cptr s)
{
	if (y < 0 || y >= COCOA_ROWS) return 0;
	if (x < 0) { n += x; s -= x; x = 0; }
	if (x + n > COCOA_COLS) n = COCOA_COLS - x;
	if (n <= 0) return 0;

	pthread_mutex_lock(&screen_lock);
	for (int i = 0; i < n; i++)
	{
		screen_cells[y][x + i].c = s[i];
		screen_cells[y][x + i].a = a;
		screen_cells[y][x + i].dirty = TRUE;
	}
	if (y == 0) message_row_dirty = TRUE;
	pthread_mutex_unlock(&screen_lock);
	cocoa_queue_redraw();
	return 0;
}

static errr Term_xtra_cocoa(int n, int v)
{
	switch (n)
	{
		case TERM_XTRA_EVENT:
		{
			int key = cocoa_pop_key(v != 0);
			if (key >= 0) Term_keypress(key);
			return 0;
		}

		case TERM_XTRA_FLUSH:
			pthread_mutex_lock(&key_lock);
			key_head = key_tail = 0;
			pthread_mutex_unlock(&key_lock);
			return 0;

		case TERM_XTRA_SHAPE:
			pthread_mutex_lock(&screen_lock);
			cursor_visible = (v != 0);
			pthread_mutex_unlock(&screen_lock);
			cocoa_queue_redraw();
			return 0;

		case TERM_XTRA_FROSH:
		case TERM_XTRA_FRESH:
		case TERM_XTRA_REACT:
			cocoa_capture_message_from_screen();
			cocoa_queue_redraw();
			return 0;

		case TERM_XTRA_NOISE:
			NSBeep();
			return 0;

		case TERM_XTRA_DELAY:
			if (v > 0) usleep(1000 * v);
			return 0;

		case TERM_XTRA_ALIVE:
		case TERM_XTRA_LEVEL:
		case TERM_XTRA_SOUND:
		case TERM_XTRA_BORED:
			return 0;
	}

	return 1;
}

errr init_cocoa(int argc, char **argv, unsigned char *new_game)
{
	(void)argc;
	(void)argv;
	(void)new_game;

	pthread_mutex_lock(&screen_lock);
	for (int y = 0; y < COCOA_ROWS; y++)
	{
		for (int x = 0; x < COCOA_COLS; x++)
		{
			screen_cells[y][x].c = ' ';
			screen_cells[y][x].a = TERM_DARK;
			screen_cells[y][x].dirty = TRUE;
		}
	}
	pthread_mutex_unlock(&screen_lock);

	term_init(&term_screen_cocoa, COCOA_COLS, COCOA_ROWS, 1024);
	term_screen_cocoa.soft_cursor = TRUE;
	term_screen_cocoa.never_frosh = TRUE;
	term_screen_cocoa.attr_blank = TERM_DARK;
	term_screen_cocoa.char_blank = ' ';
	term_screen_cocoa.xtra_hook = Term_xtra_cocoa;
	term_screen_cocoa.curs_hook = Term_curs_cocoa;
	term_screen_cocoa.wipe_hook = Term_wipe_cocoa;
	term_screen_cocoa.text_hook = Term_text_cocoa;

	angband_term[0] = &term_screen_cocoa;
	Term_activate(&term_screen_cocoa);
	cocoa_queue_redraw();

	return 0;
}

@interface ZBCocoaAppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate, NSMenuItemValidation, ZBDeathRestartPresenter>
@end

@implementation ZBCocoaAppDelegate {
	NSWindow *_window;
	NSSplitView *_splitView;
	BOOL _inspectorVisible;
	BOOL _deathOptionsShown;
	BOOL _deathOptionsVisible;
	NSPanel *_commandPanel;
	NSSearchField *_commandSearch;
	NSTableView *_commandTable;
	NSArray<NSDictionary<NSString *, id> *> *_commands;
	NSArray<NSDictionary<NSString *, id> *> *_filteredCommands;
	NSWindow *_saveManagerWindow;
	NSTextView *_saveManagerTextView;
	NSWindow *_morgueWindow;
	NSTextView *_morgueTextView;
	BOOL _allowTerminate;
	BOOL _isRelaunching;
	BOOL _launchNewGame;
}

- (NSURL *)applicationSupportURL {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
	NSURL *url = [base URLByAppendingPathComponent:@"ZangbandNative" isDirectory:YES];
	[fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
	return url;
}

- (NSURL *)preparedLibURL {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *support = [self applicationSupportURL];
	NSURL *target = [support URLByAppendingPathComponent:@"lib" isDirectory:YES];
	NSURL *marker = [target URLByAppendingPathComponent:@"file/news.txt"];

	if (![fm fileExistsAtPath:marker.path])
	{
		[fm removeItemAtURL:target error:nil];
		NSURL *source = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"lib" isDirectory:YES];
		NSError *error = nil;
		if (![fm copyItemAtURL:source toURL:target error:&error])
		{
			NSLog(@"Unable to prepare Zangband support files: %@", error);
		}
	}

	return target;
}

- (BOOL)hasNativeSaveFilesAtSupportURL:(NSURL *)supportURL {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *saveURL = [[supportURL URLByAppendingPathComponent:@"lib" isDirectory:YES] URLByAppendingPathComponent:@"save" isDirectory:YES];
	NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:saveURL
	                             includingPropertiesForKeys:@[NSURLIsRegularFileKey]
	                                                options:NSDirectoryEnumerationSkipsHiddenFiles
	                                                  error:nil] ?: @[];

	for (NSURL *fileURL in files)
	{
		if ([fileURL.lastPathComponent isEqualToString:@"makefile.zb"]) continue;

		NSNumber *isRegular = nil;
		[fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
		if (isRegular.boolValue) return YES;
	}

	return NO;
}

- (NSDictionary<NSString *, id> *)commandWithName:(NSString *)name key:(NSString *)key sequence:(NSString *)sequence detail:(NSString *)detail {
	return @{ @"name": name, @"key": key, @"sequence": sequence, @"detail": detail };
}

- (NSArray<NSDictionary<NSString *, id> *> *)commands {
	if (_commands) return _commands;

	_commands = @[
		[self commandWithName:@"Move north" key:@"8 / Up" sequence:ZBKeyString('8') detail:@"Walk or attack north"],
		[self commandWithName:@"Move south" key:@"2 / Down" sequence:ZBKeyString('2') detail:@"Walk or attack south"],
		[self commandWithName:@"Move west" key:@"4 / Left" sequence:ZBKeyString('4') detail:@"Walk or attack west"],
		[self commandWithName:@"Move east" key:@"6 / Right" sequence:ZBKeyString('6') detail:@"Walk or attack east"],
		[self commandWithName:@"Move northwest" key:@"7" sequence:ZBKeyString('7') detail:@"Walk or attack northwest"],
		[self commandWithName:@"Move northeast" key:@"9" sequence:ZBKeyString('9') detail:@"Walk or attack northeast"],
		[self commandWithName:@"Move southwest" key:@"1" sequence:ZBKeyString('1') detail:@"Walk or attack southwest"],
		[self commandWithName:@"Move southeast" key:@"3" sequence:ZBKeyString('3') detail:@"Walk or attack southeast"],
		[self commandWithName:@"Run north" key:@"Shift-Up / .8" sequence:ZBRunSequence('8') detail:@"Run north until interrupted"],
		[self commandWithName:@"Run south" key:@"Shift-Down / .2" sequence:ZBRunSequence('2') detail:@"Run south until interrupted"],
		[self commandWithName:@"Run west" key:@"Shift-Left / .4" sequence:ZBRunSequence('4') detail:@"Run west until interrupted"],
		[self commandWithName:@"Run east" key:@"Shift-Right / .6" sequence:ZBRunSequence('6') detail:@"Run east until interrupted"],
		[self commandWithName:@"Run northwest" key:@"Shift-Home / .7" sequence:ZBRunSequence('7') detail:@"Run northwest until interrupted"],
		[self commandWithName:@"Run northeast" key:@"Shift-PgUp / .9" sequence:ZBRunSequence('9') detail:@"Run northeast until interrupted"],
		[self commandWithName:@"Run southwest" key:@"Shift-End / .1" sequence:ZBRunSequence('1') detail:@"Run southwest until interrupted"],
		[self commandWithName:@"Run southeast" key:@"Shift-PgDn / .3" sequence:ZBRunSequence('3') detail:@"Run southeast until interrupted"],
		[self commandWithName:@"Wait" key:@"5" sequence:ZBKeyString('5') detail:@"Spend one turn in place"],
		[self commandWithName:@"Get item" key:@"g" sequence:ZBKeyString('g') detail:@"Pick up an item"],
		[self commandWithName:@"Inventory" key:@"i" sequence:ZBKeyString('i') detail:@"Open inventory"],
		[self commandWithName:@"Equipment" key:@"e" sequence:ZBKeyString('e') detail:@"Open equipment"],
		[self commandWithName:@"Look" key:@"l" sequence:ZBKeyString('l') detail:@"Inspect visible terrain or monsters"],
		[self commandWithName:@"Open door" key:@"o" sequence:ZBKeyString('o') detail:@"Open a nearby door or chest"],
		[self commandWithName:@"Close door" key:@"c" sequence:ZBKeyString('c') detail:@"Close a nearby door"],
		[self commandWithName:@"Rest" key:@"R" sequence:ZBKeyString('R') detail:@"Rest for a chosen duration"],
		[self commandWithName:@"Search" key:@"s" sequence:ZBKeyString('s') detail:@"Search nearby squares"],
		[self commandWithName:@"Ascend stairs" key:@"<" sequence:ZBKeyString('<') detail:@"Use upstairs"],
		[self commandWithName:@"Descend stairs" key:@">" sequence:ZBKeyString('>') detail:@"Use downstairs"],
		[self commandWithName:@"Fire missile" key:@"f" sequence:ZBKeyString('f') detail:@"Fire a ranged weapon"],
		[self commandWithName:@"Throw item" key:@"v" sequence:ZBKeyString('v') detail:@"Throw an item"],
		[self commandWithName:@"Zap wand" key:@"a" sequence:ZBKeyString('a') detail:@"Aim a wand"],
		[self commandWithName:@"Use staff" key:@"u" sequence:ZBKeyString('u') detail:@"Use a staff"],
		[self commandWithName:@"Read scroll" key:@"r" sequence:ZBKeyString('r') detail:@"Read a scroll"],
		[self commandWithName:@"Cast spell" key:@"m" sequence:ZBKeyString('m') detail:@"Cast or browse magic"],
		[self commandWithName:@"Repeat command" key:@"n" sequence:ZBKeyString('n') detail:@"Repeat the previous command"],
		[self commandWithName:@"Messages" key:@"Ctrl-P" sequence:ZBKeyString(COCOA_CTRL('P')) detail:@"Show message history"],
		[self commandWithName:@"Redraw" key:@"Ctrl-R" sequence:ZBKeyString(COCOA_CTRL('R')) detail:@"Refresh the game display"],
		[self commandWithName:@"Save" key:@"Ctrl-S" sequence:ZBKeyString(COCOA_CTRL('S')) detail:@"Save without quitting"],
		[self commandWithName:@"Save and quit" key:@"Ctrl-X" sequence:ZBKeyString(COCOA_CTRL('X')) detail:@"Save and exit"],
		[self commandWithName:@"Help" key:@"?" sequence:ZBKeyString('?') detail:@"Open Zangband help"],
		[self commandWithName:@"Escape" key:@"Esc" sequence:ZBKeyString(ESCAPE) detail:@"Cancel or back out"]
	];

	return _commands;
}

- (void)sendKeySequence:(NSString *)sequence {
	for (NSUInteger i = 0; i < sequence.length; i++)
	{
		[cocoa_view enqueueKey:(int)[sequence characterAtIndex:i]];
	}
	[_window makeFirstResponder:cocoa_view];
}

- (void)filterCommands {
	NSString *query = ZBTrim(_commandSearch.stringValue ?: @"");
	NSMutableArray<NSDictionary<NSString *, id> *> *filtered = [NSMutableArray array];

	for (NSDictionary<NSString *, id> *command in self.commands)
	{
		NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
		                      command[@"name"], command[@"key"], command[@"detail"]];
		if (!query.length || [haystack rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
		{
			[filtered addObject:command];
		}
	}

	_filteredCommands = filtered;
	[_commandTable reloadData];
	if (_filteredCommands.count) [_commandTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (void)buildCommandPanel {
	NSRect frame = NSMakeRect(0, 0, 640, 420);
	_commandPanel = [[NSPanel alloc] initWithContentRect:frame
	                                           styleMask:(NSWindowStyleMaskTitled |
	                                                      NSWindowStyleMaskClosable |
	                                                      NSWindowStyleMaskUtilityWindow)
	                                             backing:NSBackingStoreBuffered
	                                               defer:NO];
	_commandPanel.title = @"Command Palette";

	NSView *content = [[NSView alloc] initWithFrame:frame];
	_commandPanel.contentView = content;

	_commandSearch = [[NSSearchField alloc] initWithFrame:NSMakeRect(16, NSHeight(frame) - 48, NSWidth(frame) - 32, 28)];
	_commandSearch.placeholderString = @"Search commands";
	_commandSearch.delegate = self;
	_commandSearch.target = self;
	_commandSearch.action = @selector(sendSelectedCommand:);
	[content addSubview:_commandSearch];

	NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 56, NSWidth(frame) - 32, NSHeight(frame) - 116)];
	scrollView.hasVerticalScroller = YES;
	scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	_commandTable = [[NSTableView alloc] initWithFrame:scrollView.bounds];
	_commandTable.delegate = self;
	_commandTable.dataSource = self;
	_commandTable.doubleAction = @selector(sendSelectedCommand:);
	_commandTable.target = self;
	_commandTable.usesAlternatingRowBackgroundColors = YES;
	_commandTable.headerView = nil;

	NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	nameColumn.title = @"Command";
	nameColumn.width = 240;
	[_commandTable addTableColumn:nameColumn];

	NSTableColumn *keyColumn = [[NSTableColumn alloc] initWithIdentifier:@"key"];
	keyColumn.title = @"Key";
	keyColumn.width = 90;
	[_commandTable addTableColumn:keyColumn];

	NSTableColumn *detailColumn = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
	detailColumn.title = @"Detail";
	detailColumn.width = 260;
	[_commandTable addTableColumn:detailColumn];

	scrollView.documentView = _commandTable;
	[content addSubview:scrollView];

	NSButton *sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(NSWidth(frame) - 108, 16, 92, 28)];
	sendButton.title = @"Send";
	sendButton.bezelStyle = NSBezelStyleRounded;
	sendButton.target = self;
	sendButton.action = @selector(sendSelectedCommand:);
	sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
	[content addSubview:sendButton];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	(void)tableView;
	return (NSInteger)_filteredCommands.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	(void)tableView;
	if (row < 0 || row >= (NSInteger)_filteredCommands.count) return @"";
	return _filteredCommands[(NSUInteger)row][tableColumn.identifier] ?: @"";
}

- (void)controlTextDidChange:(NSNotification *)notification {
	if (notification.object == _commandSearch) [self filterCommands];
}

- (IBAction)showCommandPalette:(id)sender {
	(void)sender;
	if (!_commandPanel) [self buildCommandPanel];
	[self filterCommands];
	[_commandPanel center];
	[_commandPanel makeKeyAndOrderFront:nil];
	[_commandSearch becomeFirstResponder];
}

- (IBAction)sendSelectedCommand:(id)sender {
	(void)sender;
	NSInteger row = _commandTable.selectedRow;
	if (row < 0 && _filteredCommands.count) row = 0;
	if (row < 0 || row >= (NSInteger)_filteredCommands.count) return;

	NSDictionary<NSString *, id> *command = _filteredCommands[(NSUInteger)row];
	[self sendKeySequence:command[@"sequence"]];
	[_commandPanel orderOut:nil];
}

- (NSTextView *)textViewForReportWindow:(NSWindow * __strong *)window title:(NSString *)title frame:(NSRect)frame {
	if (*window)
	{
		NSScrollView *scrollView = (NSScrollView *)(*window).contentView;
		return (NSTextView *)scrollView.documentView;
	}

	*window = [[NSWindow alloc] initWithContentRect:frame
	                                      styleMask:(NSWindowStyleMaskTitled |
	                                                 NSWindowStyleMaskClosable |
	                                                 NSWindowStyleMaskResizable)
	                                        backing:NSBackingStoreBuffered
	                                          defer:NO];
	(*window).title = title;

	NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
	scrollView.hasVerticalScroller = YES;
	scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSTextView *textView = [[NSTextView alloc] initWithFrame:frame];
	textView.editable = NO;
	textView.selectable = YES;
	textView.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
	textView.textContainerInset = NSMakeSize(12.0, 12.0);
	scrollView.documentView = textView;
	(*window).contentView = scrollView;

	return textView;
}

- (IBAction)showSaveManager:(id)sender {
	(void)sender;
	NSRect frame = NSMakeRect(0, 0, 760, 520);
	_saveManagerTextView = [self textViewForReportWindow:&_saveManagerWindow title:@"Save Manager" frame:frame];
	_saveManagerTextView.string = ZBSaveManagerReport();
	[_saveManagerWindow center];
	[_saveManagerWindow makeKeyAndOrderFront:nil];
}

- (IBAction)showMorgueGallery:(id)sender {
	(void)sender;
	NSRect frame = NSMakeRect(0, 0, 760, 520);
	_morgueTextView = [self textViewForReportWindow:&_morgueWindow title:@"Morgue Gallery" frame:frame];
	_morgueTextView.string = ZBMorgueReport();
	[_morgueWindow center];
	[_morgueWindow makeKeyAndOrderFront:nil];
}

- (IBAction)copyMorgueSummary:(id)sender {
	(void)sender;
	NSString *summary = _morgueTextView.string.length ? _morgueTextView.string : ZBMorgueReport();
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard setString:summary forType:NSPasteboardTypeString];
}

- (IBAction)toggleInspector:(id)sender {
	(void)sender;
	_inspectorVisible = !_inspectorVisible;
	cocoa_inspector.hidden = !_inspectorVisible;
	[self splitView:_splitView resizeSubviewsWithOldSize:_splitView.bounds.size];
	[_window makeFirstResponder:cocoa_view];
}

- (IBAction)toggleTileMode:(id)sender {
	(void)sender;
	cocoa_view.tileMode = !cocoa_view.tileMode;
	[_window makeFirstResponder:cocoa_view];
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex {
	(void)splitView;
	(void)dividerIndex;
	return MAX(proposedMinimumPosition, COCOA_TERMINAL_MIN_WIDTH);
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex {
	(void)dividerIndex;
	if (!_inspectorVisible) return proposedMaximumPosition;
	return MIN(proposedMaximumPosition, NSWidth(splitView.bounds) - COCOA_INSPECTOR_MIN_WIDTH);
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview {
	(void)splitView;
	return subview == cocoa_inspector;
}

- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize {
	(void)oldSize;
	NSRect bounds = splitView.bounds;
	CGFloat divider = splitView.dividerThickness;
	CGFloat width = NSWidth(bounds);
	CGFloat height = NSHeight(bounds);

	if (!_inspectorVisible)
	{
		cocoa_view.frame = bounds;
		cocoa_inspector.frame = NSMakeRect(width, 0, 0, height);
		return;
	}

	CGFloat inspectorWidth = MIN(COCOA_INSPECTOR_WIDTH,
	                             MAX(COCOA_INSPECTOR_MIN_WIDTH,
	                                 width - COCOA_TERMINAL_MIN_WIDTH - divider));
	CGFloat terminalWidth = MAX(0.0, width - inspectorWidth - divider);

	cocoa_view.frame = NSMakeRect(0, 0, terminalWidth, height);
	cocoa_inspector.frame = NSMakeRect(terminalWidth + divider, 0, inspectorWidth, height);
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
	if (menuItem.action == @selector(toggleInspector:))
	{
		menuItem.state = _inspectorVisible ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (menuItem.action == @selector(toggleTileMode:))
	{
		menuItem.state = cocoa_view.tileMode ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (menuItem.action == @selector(copyMorgueSummary:))
	{
		return YES;
	}

	return YES;
}

- (BOOL)nativeDeathScreenIsVisible {
	if (!(p_ptr && p_ptr->state.is_dead)) return NO;

	for (NSString *row in cocoa_snapshot_rows())
	{
		if ([row rangeOfString:@"Dump char record" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		    [row rangeOfString:@"Show char info" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		    [row rangeOfString:@"Show top scores" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		    [row rangeOfString:@"Do you really want to exit" options:NSCaseInsensitiveSearch].location != NSNotFound)
		{
			return YES;
		}
	}

	return NO;
}

- (void)maybeShowDeathRestartOptions {
	if (_deathOptionsShown || _deathOptionsVisible || _isRelaunching || _allowTerminate) return;
	if (![self nativeDeathScreenIsVisible]) return;

	_deathOptionsShown = YES;
	[self showDeathRestartOptionsCanStay:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	(void)notification;
	_launchNewGame = [NSProcessInfo.processInfo.arguments containsObject:@"--new-game"];
	cocoa_app_delegate = self;

	NSRect frame = NSMakeRect(0, 0, COCOA_DEFAULT_WINDOW_WIDTH, COCOA_DEFAULT_WINDOW_HEIGHT);
	_window = [[NSWindow alloc] initWithContentRect:frame
	                                      styleMask:(NSWindowStyleMaskTitled |
	                                                 NSWindowStyleMaskClosable |
	                                                 NSWindowStyleMaskMiniaturizable |
	                                                 NSWindowStyleMaskResizable)
							 backing:NSBackingStoreBuffered
							  defer:NO];
	_window.title = @"Zangband Native";
	_window.minSize = NSMakeSize(COCOA_TERMINAL_MIN_WIDTH + COCOA_INSPECTOR_MIN_WIDTH + 20.0, 600.0);

	_splitView = [[NSSplitView alloc] initWithFrame:frame];
	_splitView.vertical = YES;
	_splitView.dividerStyle = NSSplitViewDividerStyleThin;
	_splitView.delegate = self;
	_splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSRect terminalFrame = NSMakeRect(0, 0, NSWidth(frame) - COCOA_INSPECTOR_WIDTH, NSHeight(frame));
	cocoa_view = [[ZBCocoaTermView alloc] initWithFrame:terminalFrame];
	cocoa_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[_splitView addSubview:cocoa_view];

	NSRect inspectorFrame = NSMakeRect(NSWidth(frame) - COCOA_INSPECTOR_WIDTH, 0, COCOA_INSPECTOR_WIDTH, NSHeight(frame));
	cocoa_inspector = [[ZBCocoaInspectorView alloc] initWithFrame:inspectorFrame];
	cocoa_inspector.autoresizingMask = NSViewHeightSizable;
	[_splitView addSubview:cocoa_inspector];

	_inspectorVisible = YES;
	_window.contentView = _splitView;
	[self splitView:_splitView resizeSubviewsWithOldSize:frame.size];
	[_window center];
	[_window makeKeyAndOrderFront:nil];
	[_window makeFirstResponder:cocoa_view];
	[NSApp activateIgnoringOtherApps:YES];

	NSURL *supportURL = [self applicationSupportURL];
	NSURL *libURL = [self preparedLibURL];
	BOOL shouldGenerateName = _launchNewGame || ![self hasNativeSaveFilesAtSupportURL:supportURL];
	NSString *generatedName = shouldGenerateName ? ZBRandomCharacterName() : nil;

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			setenv("ANGBAND_PATH", libURL.fileSystemRepresentation, 1);
			chdir(supportURL.fileSystemRepresentation);

			NSMutableArray<NSString *> *gameArguments = [NSMutableArray arrayWithObjects:@"zangband", @"-mcocoa", nil];
			if (generatedName.length)
			{
				[gameArguments addObject:[@"-u" stringByAppendingString:generatedName]];
			}
			if (self->_launchNewGame)
			{
				[gameArguments addObject:@"-n"];
			}

			int gameArgc = (int)gameArguments.count;
			char **gameArgv = calloc((size_t)gameArgc + 1, sizeof(char *));
			for (int i = 0; i < gameArgc; i++)
			{
				gameArgv[i] = (char *)[gameArguments[(NSUInteger)i] UTF8String];
			}

			zangband_game_main(gameArgc, gameArgv);
			free(gameArgv);

			BOOL endedFromDeath = (p_ptr && p_ptr->state.is_dead);
			dispatch_async(dispatch_get_main_queue(), ^{
				self->_allowTerminate = YES;
				if (endedFromDeath)
				{
					[self showDeathRestartOptionsCanStay:NO];
				}
				else
				{
					[NSApp terminate:nil];
				}
			});
		}
	});
}

- (IBAction)saveGame:(id)sender {
	(void)sender;
	[cocoa_view enqueueKey:COCOA_CTRL('S')];
}

- (IBAction)saveAndQuit:(id)sender {
	(void)sender;
	[cocoa_view enqueueKey:COCOA_CTRL('X')];
}

- (BOOL)confirmRelaunchForNewGame:(BOOL)newGame {
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = newGame ? @"Start a new game?" : @"Restart Zangband Native?";
	alert.informativeText = @"The current native backend runs the legacy game core in-process, so restarting relaunches the app. Save first if you want to keep the current run.";
	[alert addButtonWithTitle:newGame ? @"New Game" : @"Restart"];
	[alert addButtonWithTitle:@"Cancel"];
	alert.alertStyle = NSAlertStyleWarning;
	return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)relaunchWithNewGame:(BOOL)newGame confirm:(BOOL)confirm {
	if (confirm && ![self confirmRelaunchForNewGame:newGame]) return;

	NSURL *executableURL = NSBundle.mainBundle.executableURL;
	if (!executableURL) return;

	NSTask *task = [[NSTask alloc] init];
	task.executableURL = executableURL;
	task.arguments = newGame ? @[@"--new-game"] : @[];

	NSError *error = nil;
	if (![task launchAndReturnError:&error])
	{
		NSAlert *alert = [NSAlert alertWithError:error];
		[alert runModal];
		return;
	}

	_isRelaunching = YES;
	[NSApp terminate:nil];
}

- (void)relaunchWithNewGame:(BOOL)newGame {
	[self relaunchWithNewGame:newGame confirm:YES];
}

- (void)showDeathRestartOptionsCanStay:(BOOL)canStay {
	_deathOptionsVisible = YES;

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Your run has ended";
	alert.informativeText = canStay ? @"Start a new character now, restart the native app, or return to the death screen." :
	                                  @"Start a new character now, restart the native app, or close Zangband Native.";
	[alert addButtonWithTitle:@"New Game"];
	[alert addButtonWithTitle:@"Restart App"];
	[alert addButtonWithTitle:canStay ? @"Stay on Death Screen" : @"Close"];
	alert.alertStyle = NSAlertStyleInformational;

	NSModalResponse response = [alert runModal];
	_deathOptionsVisible = NO;

	if (response == NSAlertFirstButtonReturn)
	{
		[self relaunchWithNewGame:YES confirm:NO];
	}
	else if (response == NSAlertSecondButtonReturn)
	{
		[self relaunchWithNewGame:NO confirm:NO];
	}
	else
	{
		if (!canStay)
		{
			[NSApp terminate:nil];
		}
	}
}

- (IBAction)newGame:(id)sender {
	(void)sender;
	[self relaunchWithNewGame:YES];
}

- (IBAction)restartGame:(id)sender {
	(void)sender;
	[self relaunchWithNewGame:NO];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	(void)sender;
	if (_allowTerminate || _isRelaunching) return NSTerminateNow;
	if (!cocoa_view) return NSTerminateNow;

	[cocoa_view enqueueKey:COCOA_CTRL('X')];
	return NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
	(void)sender;
	return YES;
}

@end

static void ZBCocoaInstallMainMenu(void)
{
	NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

	NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:appItem];

	NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Zangband Native"];
	[appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit Zangband Native" action:@selector(terminate:) keyEquivalent:@"q"]];
	appItem.submenu = appMenu;

	NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:fileItem];

	NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New Game" action:@selector(newGame:) keyEquivalent:@"n"]];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Restart" action:@selector(restartGame:) keyEquivalent:@"r"]];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveGame:) keyEquivalent:@"s"]];
	NSMenuItem *saveAndQuitItem = [[NSMenuItem alloc] initWithTitle:@"Save and Quit" action:@selector(saveAndQuit:) keyEquivalent:@"s"];
	saveAndQuitItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	[fileMenu addItem:saveAndQuitItem];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Save Manager" action:@selector(showSaveManager:) keyEquivalent:@""]];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Morgue Gallery" action:@selector(showMorgueGallery:) keyEquivalent:@""]];
	[fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Copy Morgue Summary" action:@selector(copyMorgueSummary:) keyEquivalent:@""]];
	fileItem.submenu = fileMenu;

	NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:editItem];

	NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
	[editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]];
	editItem.submenu = editMenu;

	NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:viewItem];

	NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
	NSMenuItem *inspectorItem = [[NSMenuItem alloc] initWithTitle:@"Side Inspector" action:@selector(toggleInspector:) keyEquivalent:@"i"];
	inspectorItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	[viewMenu addItem:inspectorItem];
	NSMenuItem *tileItem = [[NSMenuItem alloc] initWithTitle:@"Tile Mode" action:@selector(toggleTileMode:) keyEquivalent:@"t"];
	tileItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	[viewMenu addItem:tileItem];
	[viewMenu addItem:[NSMenuItem separatorItem]];
	[viewMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]];
	viewItem.submenu = viewMenu;

	NSMenuItem *commandItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:commandItem];

	NSMenu *commandMenu = [[NSMenu alloc] initWithTitle:@"Commands"];
	NSMenuItem *paletteItem = [[NSMenuItem alloc] initWithTitle:@"Command Palette" action:@selector(showCommandPalette:) keyEquivalent:@"p"];
	paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	[commandMenu addItem:paletteItem];
	commandItem.submenu = commandMenu;

	NSApp.mainMenu = mainMenu;
}

int main(int argc, const char *argv[])
{
	(void)argc;
	(void)argv;

	@autoreleasepool
	{
		NSApplication *app = NSApplication.sharedApplication;
		app.activationPolicy = NSApplicationActivationPolicyRegular;
		ZBCocoaInstallMainMenu();

		ZBCocoaAppDelegate *delegate = [[ZBCocoaAppDelegate alloc] init];
		app.delegate = delegate;
		[app run];
	}

	return 0;
}
