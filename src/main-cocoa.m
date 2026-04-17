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
#define COCOA_CTRL(c) ((c) & 0x1F)

extern int zangband_game_main(int argc, char **argv);

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
static ZBCocoaTermView *cocoa_view = nil;

static void cocoa_queue_redraw(void);
static void cocoa_enqueue_key(int key);

@interface ZBCocoaTermView : NSView <NSMenuItemValidation>
- (void)enqueueKey:(int)key;
@end

@implementation ZBCocoaTermView {
	NSFont *_font;
	NSFont *_boldFont;
	CGFloat _cellWidth;
	CGFloat _cellHeight;
	CGFloat _baselineOffset;
	CGFloat _contentX;
	CGFloat _contentY;
	NSArray<NSColor *> *_colors;
}

- (instancetype)initWithFrame:(NSRect)frame {
	self = [super initWithFrame:frame];
	if (!self) return nil;

	_font = [NSFont fontWithName:@"Menlo-Regular" size:16.0] ?: [NSFont monospacedSystemFontOfSize:16.0 weight:NSFontWeightRegular];
	_boldFont = [NSFont fontWithName:@"Menlo-Bold" size:16.0] ?: [NSFont monospacedSystemFontOfSize:16.0 weight:NSFontWeightBold];

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

- (void)drawRect:(NSRect)dirtyRect {
	(void)dirtyRect;
	[self recalculateOrigin];

	[[NSColor colorWithCalibratedRed:0.025 green:0.028 blue:0.026 alpha:1.0] setFill];
	NSRectFill(self.bounds);

	NSRect terminalRect = NSMakeRect(_contentX, _contentY, (CGFloat)COCOA_COLS * _cellWidth, (CGFloat)COCOA_ROWS * _cellHeight);
	[[NSColor blackColor] setFill];
	NSRectFill(terminalRect);

	NSMutableString *run = [NSMutableString stringWithCapacity:COCOA_COLS];
	NSMutableDictionary<NSAttributedStringKey, id> *attrs = [@{ NSFontAttributeName: _font } mutableCopy];

	pthread_mutex_lock(&screen_lock);
	for (int y = 0; y < COCOA_ROWS; y++)
	{
		int x = 0;
		while (x < COCOA_COLS)
		{
			byte attr = screen_cells[y][x].a;
			int start = x;
			[run setString:@""];

			while (x < COCOA_COLS && screen_cells[y][x].a == attr)
			{
				char c = screen_cells[y][x].c ? screen_cells[y][x].c : ' ';
				[run appendFormat:@"%C", (unichar)c];
				screen_cells[y][x].dirty = FALSE;
				x++;
			}

			attrs[NSForegroundColorAttributeName] = [self colorForAttr:attr];
			attrs[NSFontAttributeName] = (attr >= 8) ? _boldFont : _font;
			[run drawAtPoint:NSMakePoint(_contentX + (CGFloat)start * _cellWidth,
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
		case 83: [self enqueueKey:'1']; return YES;
		case 84: [self enqueueKey:'2']; return YES;
		case 85: [self enqueueKey:'3']; return YES;
		case 86: [self enqueueKey:'4']; return YES;
		case 87: [self enqueueKey:'5']; return YES;
		case 88: [self enqueueKey:'6']; return YES;
		case 89: [self enqueueKey:'7']; return YES;
		case 91: [self enqueueKey:'8']; return YES;
		case 92: [self enqueueKey:'9']; return YES;
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

	return YES;
}

- (void)keyDown:(NSEvent *)event {
	if ([self enqueueControlKeyFromEvent:event]) return;
	if ([self enqueueKeypadKeyFromEvent:event]) return;

	NSString *chars = event.charactersIgnoringModifiers ?: @"";
	unichar key = chars.length ? [chars characterAtIndex:0] : 0;

	switch (key)
	{
		case NSUpArrowFunctionKey:    [self enqueueKey:'8']; return;
		case NSDownArrowFunctionKey:  [self enqueueKey:'2']; return;
		case NSRightArrowFunctionKey: [self enqueueKey:'6']; return;
		case NSLeftArrowFunctionKey:  [self enqueueKey:'4']; return;
		case NSHomeFunctionKey:       [self enqueueKey:'7']; return;
		case NSEndFunctionKey:        [self enqueueKey:'1']; return;
		case NSPageUpFunctionKey:     [self enqueueKey:'9']; return;
		case NSPageDownFunctionKey:   [self enqueueKey:'3']; return;
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

@interface ZBCocoaAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ZBCocoaAppDelegate {
	NSWindow *_window;
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

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	(void)notification;
	_launchNewGame = [NSProcessInfo.processInfo.arguments containsObject:@"--new-game"];

	NSRect frame = NSMakeRect(0, 0, 1120, 720);
	_window = [[NSWindow alloc] initWithContentRect:frame
	                                      styleMask:(NSWindowStyleMaskTitled |
	                                                 NSWindowStyleMaskClosable |
	                                                 NSWindowStyleMaskMiniaturizable |
	                                                 NSWindowStyleMaskResizable)
	                                        backing:NSBackingStoreBuffered
	                                          defer:NO];
	_window.title = @"Zangband Native";
	_window.minSize = NSMakeSize(860, 560);
	cocoa_view = [[ZBCocoaTermView alloc] initWithFrame:frame];
	_window.contentView = cocoa_view;
	[_window center];
	[_window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];

	NSURL *supportURL = [self applicationSupportURL];
	NSURL *libURL = [self preparedLibURL];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			setenv("ANGBAND_PATH", libURL.fileSystemRepresentation, 1);
			chdir(supportURL.fileSystemRepresentation);

			char *normalArgv[] = { "zangband", "-mcocoa", NULL };
			char *newGameArgv[] = { "zangband", "-mcocoa", "-n", NULL };
			zangband_game_main(self->_launchNewGame ? 3 : 2,
			                   self->_launchNewGame ? newGameArgv : normalArgv);

			dispatch_async(dispatch_get_main_queue(), ^{
				self->_allowTerminate = YES;
				[NSApp terminate:nil];
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

- (void)relaunchWithNewGame:(BOOL)newGame {
	if (![self confirmRelaunchForNewGame:newGame]) return;

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
	fileItem.submenu = fileMenu;

	NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[mainMenu addItem:editItem];

	NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
	[editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]];
	editItem.submenu = editMenu;

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
