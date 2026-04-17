#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static const int ZBTerminalCols = 80;
static const int ZBTerminalRows = 24;
static const CGFloat ZBMinimumContentInset = 18.0;

typedef struct {
    unichar ch;
    uint8_t fg;
    BOOL bold;
    BOOL dirty;
} ZBCell;

typedef NS_ENUM(NSUInteger, ZBParserState) {
    ZBParserNormal,
    ZBParserEscape,
    ZBParserCSI,
    ZBParserOSC,
    ZBParserCharset,
    ZBParserOSCMaybeEnd
};

@interface ZBTerminalView : NSView
@end

@implementation ZBTerminalView {
    int _masterFd;
    pid_t _childPid;
    dispatch_source_t _readSource;

    int _cols;
    int _rows;
    int _cursorCol;
    int _cursorRow;
    uint8_t _fg;
    BOOL _bold;
    ZBCell *_cells;

    NSFont *_font;
    NSFont *_boldFont;
    CGFloat _cellWidth;
    CGFloat _cellHeight;
    CGFloat _baselineOffset;
    CGFloat _contentX;
    CGFloat _contentY;
    NSArray<NSColor *> *_colors;
    NSColor *_floorColor;
    NSColor *_grassColor;
    NSColor *_dirtColor;
    NSColor *_sandColor;
    NSColor *_treeColor;
    NSColor *_treePurpleColor;
    NSColor *_rockColor;
    NSColor *_wallColor;
    NSColor *_swampColor;
    NSColor *_waterColor;
    NSColor *_lavaColor;
    NSColor *_acidColor;
    CGFloat _fontSize;
    BOOL _needsFullRedraw;

    ZBParserState _parserState;
    char _csi[128];
    size_t _csiLen;
    BOOL _csiPrivate;
    int _savedCursorCol;
    int _savedCursorRow;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _masterFd = -1;
    _childPid = -1;
    _cols = ZBTerminalCols;
    _rows = ZBTerminalRows;
    _fg = 1;
    _bold = NO;
    _parserState = ZBParserNormal;
    _savedCursorCol = 0;
    _savedCursorRow = 0;

    _fontSize = 16.0;
    [self updateFontMetrics];

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

    _floorColor = [NSColor colorWithCalibratedRed:0.36 green:0.39 blue:0.36 alpha:1.0];
    _grassColor = [NSColor colorWithCalibratedRed:0.25 green:0.45 blue:0.28 alpha:1.0];
    _dirtColor = [NSColor colorWithCalibratedRed:0.42 green:0.34 blue:0.24 alpha:1.0];
    _sandColor = [NSColor colorWithCalibratedRed:0.50 green:0.44 blue:0.28 alpha:1.0];
    _treeColor = [NSColor colorWithCalibratedRed:0.30 green:0.48 blue:0.24 alpha:1.0];
    _treePurpleColor = [NSColor colorWithCalibratedRed:0.43 green:0.34 blue:0.50 alpha:1.0];
    _rockColor = [NSColor colorWithCalibratedRed:0.43 green:0.43 blue:0.39 alpha:1.0];
    _wallColor = [NSColor colorWithCalibratedRed:0.62 green:0.65 blue:0.61 alpha:1.0];
    _swampColor = [NSColor colorWithCalibratedRed:0.30 green:0.42 blue:0.30 alpha:1.0];
    _waterColor = [NSColor colorWithCalibratedRed:0.28 green:0.40 blue:0.55 alpha:1.0];
    _lavaColor = [NSColor colorWithCalibratedRed:0.58 green:0.24 blue:0.18 alpha:1.0];
    _acidColor = [NSColor colorWithCalibratedRed:0.36 green:0.54 blue:0.24 alpha:1.0];

    [self allocateGridPreserving:NO];
    [self recalculateContentOrigin];
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
    [self resizeGridForBounds];
    [self startGameIfNeeded];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self recalculateContentOrigin];
    _needsFullRedraw = YES;
    [self setNeedsDisplay:YES];
}

- (void)dealloc {
    [self stopGame];
    free(_cells);
}

- (void)updateFontMetrics {
    NSFont *menlo = [NSFont fontWithName:@"Menlo-Regular" size:_fontSize];
    NSFont *menloBold = [NSFont fontWithName:@"Menlo-Bold" size:_fontSize];

    _font = menlo ?: [NSFont monospacedSystemFontOfSize:_fontSize weight:NSFontWeightRegular];
    _boldFont = menloBold ?: [NSFont monospacedSystemFontOfSize:_fontSize weight:NSFontWeightBold];

    NSDictionary *attrs = @{ NSFontAttributeName: _font };
    _cellWidth = ceil([@"W" sizeWithAttributes:attrs].width);
    _cellHeight = ceil(_font.ascender - _font.descender + _font.leading) + 3.0;
    _baselineOffset = floor((_cellHeight - (_font.ascender - _font.descender)) / 2.0);
    [self recalculateContentOrigin];
}

- (void)recalculateContentOrigin {
    CGFloat terminalWidth = (CGFloat)_cols * _cellWidth;
    CGFloat terminalHeight = (CGFloat)_rows * _cellHeight;
    CGFloat availableWidth = NSWidth(self.bounds);
    CGFloat availableHeight = NSHeight(self.bounds);

    _contentX = floor(MAX(ZBMinimumContentInset, (availableWidth - terminalWidth) / 2.0));
    _contentY = floor(MAX(ZBMinimumContentInset, (availableHeight - terminalHeight) / 2.0));
}

- (NSRect)terminalRect {
    return NSMakeRect(_contentX,
                      _contentY,
                      (CGFloat)_cols * _cellWidth,
                      (CGFloat)_rows * _cellHeight);
}

- (NSRect)cellRectAtColumn:(int)col row:(int)row {
    return NSMakeRect(_contentX + (CGFloat)col * _cellWidth,
                      _contentY + (CGFloat)row * _cellHeight,
                      _cellWidth,
                      _cellHeight);
}

- (void)markCellDirtyAtColumn:(int)col row:(int)row {
    if (col < 0 || col >= _cols || row < 0 || row >= _rows) return;
    _cells[row * _cols + col].dirty = YES;
}

- (void)markRowDirty:(int)row {
    if (row < 0 || row >= _rows) return;
    for (int col = 0; col < _cols; col++) {
        _cells[row * _cols + col].dirty = YES;
    }
}

- (void)markAllDirty {
    for (int i = 0; i < _cols * _rows; i++) {
        _cells[i].dirty = YES;
    }
    _needsFullRedraw = YES;
}

- (void)allocateGridPreserving:(BOOL)preserve {
    int oldCols = _cols;
    int oldRows = _rows;
    ZBCell *oldCells = _cells;

    _cells = calloc((size_t)_cols * (size_t)_rows, sizeof(ZBCell));
    for (int i = 0; i < _cols * _rows; i++) {
        _cells[i].ch = ' ';
        _cells[i].fg = 1;
        _cells[i].bold = NO;
        _cells[i].dirty = YES;
    }

    if (preserve && oldCells) {
        int copyRows = MIN(oldRows, _rows);
        int copyCols = MIN(oldCols, _cols);
        for (int row = 0; row < copyRows; row++) {
            memcpy(&_cells[row * _cols], &oldCells[row * oldCols], sizeof(ZBCell) * (size_t)copyCols);
        }
    }

    free(oldCells);
    _cursorCol = MIN(_cursorCol, _cols - 1);
    _cursorRow = MIN(_cursorRow, _rows - 1);
}

- (void)resizeGridForBounds {
    [self recalculateContentOrigin];
    [self updatePtyWindowSize];
    [self markAllDirty];
    [self setNeedsDisplay:YES];
}

- (NSURL *)applicationSupportURL {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *url = [base URLByAppendingPathComponent:@"Zangband" isDirectory:YES];
    [fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

- (NSURL *)preparedLibURL {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [self applicationSupportURL];
    NSURL *target = [support URLByAppendingPathComponent:@"lib" isDirectory:YES];
    NSURL *marker = [target URLByAppendingPathComponent:@"file/news.txt"];

    if (![fm fileExistsAtPath:marker.path]) {
        [fm removeItemAtURL:target error:nil];
        NSURL *source = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"lib" isDirectory:YES];
        NSError *error = nil;
        if (![fm copyItemAtURL:source toURL:target error:&error]) {
            NSLog(@"Unable to prepare Zangband support files: %@", error);
        }
    }

    return target;
}

- (void)startGameIfNeeded {
    [self startGameIfNeededForNewGame:NO];
}

- (void)startGameIfNeededForNewGame:(BOOL)newGame {
    if (_childPid > 0) return;

    NSURL *binaryURL = [NSBundle.mainBundle URLForResource:@"zangband" withExtension:nil];
    NSURL *libURL = [self preparedLibURL];
    NSURL *supportURL = [self applicationSupportURL];
    if (!binaryURL || !libURL) return;

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)_cols;
    ws.ws_row = (unsigned short)_rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        NSLog(@"forkpty failed: %s", strerror(errno));
        return;
    }

    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("ANGBAND_PATH", libURL.fileSystemRepresentation, 1);
        chdir(supportURL.fileSystemRepresentation);

        const char *binary = binaryURL.fileSystemRepresentation;
        char *const argv[] = { "zangband", "-mgcu", newGame ? "-n" : NULL, NULL };
        execv(binary, argv);
        _exit(127);
    }

    _masterFd = master;
    _childPid = pid;
    fcntl(_masterFd, F_SETFL, fcntl(_masterFd, F_GETFL, 0) | O_NONBLOCK);

    __weak typeof(self) weakSelf = self;
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_masterFd, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_event_handler(_readSource, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        uint8_t buffer[8192];
        for (;;) {
            ssize_t n = read(strongSelf->_masterFd, buffer, sizeof(buffer));
            if (n > 0) {
                NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)n];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf consumeData:data];
                });
            } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                break;
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf handleChildExit];
                });
                break;
            }
        }
    });
    dispatch_source_set_cancel_handler(_readSource, ^{
        close(master);
    });
    dispatch_resume(_readSource);
}

- (void)handleChildExit {
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }

    if (_childPid > 0) {
        int status = 0;
        waitpid(_childPid, &status, WNOHANG);
    }

    _masterFd = -1;
    _childPid = -1;
}

- (void)stopGame {
    pid_t child = _childPid;

    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    } else if (_masterFd >= 0) {
        close(_masterFd);
    }

    _masterFd = -1;
    _childPid = -1;

    if (child > 0) {
        kill(child, SIGHUP);
        waitpid(child, NULL, WNOHANG);
    }
}

- (void)restartWithNewGame:(BOOL)newGame {
    [self stopGame];
    _cursorCol = 0;
    _cursorRow = 0;
    _fg = 1;
    _bold = NO;
    [self clearScreen];
    [self setNeedsDisplay:YES];
    [self startGameIfNeededForNewGame:newGame];
}

- (IBAction)newGame:(id)sender {
    (void)sender;
    [self restartWithNewGame:YES];
}

- (IBAction)restartGame:(id)sender {
    (void)sender;
    [self restartWithNewGame:NO];
}

- (void)setTerminalFontSize:(CGFloat)fontSize {
    _fontSize = MIN(MAX(fontSize, 10.0), 28.0);
    [self updateFontMetrics];
    [self resizeGridForBounds];
    [self setNeedsDisplay:YES];
}

- (IBAction)increaseFontSize:(id)sender {
    (void)sender;
    [self setTerminalFontSize:_fontSize + 1.0];
}

- (IBAction)decreaseFontSize:(id)sender {
    (void)sender;
    [self setTerminalFontSize:_fontSize - 1.0];
}

- (IBAction)resetFontSize:(id)sender {
    (void)sender;
    [self setTerminalFontSize:16.0];
}

- (void)updatePtyWindowSize {
    if (_masterFd < 0) return;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = ZBTerminalCols;
    ws.ws_row = ZBTerminalRows;
    ioctl(_masterFd, TIOCSWINSZ, &ws);
}

- (void)writeBytes:(const char *)bytes length:(size_t)length {
    if (_masterFd < 0 || length == 0) return;
    (void)write(_masterFd, bytes, length);
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers ?: @"";
    unichar key = chars.length ? [chars characterAtIndex:0] : 0;

    switch (key) {
        case NSUpArrowFunctionKey:    [self writeBytes:"\033[A" length:3]; return;
        case NSDownArrowFunctionKey:  [self writeBytes:"\033[B" length:3]; return;
        case NSRightArrowFunctionKey: [self writeBytes:"\033[C" length:3]; return;
        case NSLeftArrowFunctionKey:  [self writeBytes:"\033[D" length:3]; return;
        case NSDeleteCharacter:
        case NSBackspaceCharacter:    [self writeBytes:"\177" length:1]; return;
        case 0x1B:                    [self writeBytes:"\033" length:1]; return;
        case '\r':
        case '\n':                    [self writeBytes:"\r" length:1]; return;
        default: break;
    }

    NSData *data = [chars dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        [self writeBytes:data.bytes length:data.length];
    }
}

- (void)consumeData:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [self consumeByte:bytes[i]];
    }
    [self scheduleDirtyRedraw];
}

- (void)scheduleDirtyRedraw {
    if (_needsFullRedraw) {
        [self setNeedsDisplay:YES];
        return;
    }

    NSRect dirty = NSZeroRect;
    BOOL hasDirty = NO;

    for (int row = 0; row < _rows; row++) {
        for (int col = 0; col < _cols; col++) {
            if (!_cells[row * _cols + col].dirty) continue;

            NSRect cellRect = [self cellRectAtColumn:col row:row];
            dirty = hasDirty ? NSUnionRect(dirty, cellRect) : cellRect;
            hasDirty = YES;
        }
    }

    if (hasDirty) {
        [self setNeedsDisplayInRect:NSInsetRect(dirty, -1.0, -1.0)];
    }
}

- (void)consumeByte:(uint8_t)b {
    switch (_parserState) {
        case ZBParserNormal:
            if (b == 0x1B) {
                _parserState = ZBParserEscape;
            } else {
                [self putByte:b];
            }
            break;

        case ZBParserEscape:
            if (b == '[') {
                _csiLen = 0;
                _csiPrivate = NO;
                _parserState = ZBParserCSI;
            } else if (b == ']') {
                _parserState = ZBParserOSC;
            } else if (b == '(' || b == ')') {
                _parserState = ZBParserCharset;
            } else if (b == '7') {
                _savedCursorCol = _cursorCol;
                _savedCursorRow = _cursorRow;
                _parserState = ZBParserNormal;
            } else if (b == '8') {
                _cursorCol = MIN(MAX(_savedCursorCol, 0), _cols - 1);
                _cursorRow = MIN(MAX(_savedCursorRow, 0), _rows - 1);
                _parserState = ZBParserNormal;
            } else if (b == 'c') {
                _fg = 1;
                _bold = NO;
                _cursorCol = 0;
                _cursorRow = 0;
                [self clearScreen];
                _parserState = ZBParserNormal;
            } else {
                _parserState = ZBParserNormal;
            }
            break;

        case ZBParserCSI:
            if (b >= 0x40 && b <= 0x7E) {
                [self handleCSI:(char)b];
                _parserState = ZBParserNormal;
            } else if (_csiLen + 1 < sizeof(_csi)) {
                _csi[_csiLen++] = (char)b;
            }
            break;

        case ZBParserOSC:
            if (b == 0x07) {
                _parserState = ZBParserNormal;
            } else if (b == 0x1B) {
                _parserState = ZBParserOSCMaybeEnd;
            }
            break;

        case ZBParserOSCMaybeEnd:
            _parserState = (b == '\\') ? ZBParserNormal : ZBParserOSC;
            break;

        case ZBParserCharset:
            _parserState = ZBParserNormal;
            break;
    }
}

- (void)putByte:(uint8_t)b {
    if (b == '\r') {
        _cursorCol = 0;
        return;
    }
    if (b == '\n') {
        [self moveToNextLine];
        return;
    }
    if (b == '\b') {
        _cursorCol = MAX(0, _cursorCol - 1);
        return;
    }
    if (b == '\t') {
        _cursorCol = MIN(_cols - 1, (_cursorCol + 8) & ~7);
        return;
    }
    if (b < 0x20) return;

    ZBCell *cell = &_cells[_cursorRow * _cols + _cursorCol];
    if (cell->ch != (unichar)b || cell->fg != _fg || cell->bold != _bold) {
        cell->ch = (unichar)b;
        cell->fg = _fg;
        cell->bold = _bold;
        cell->dirty = YES;
    }

    _cursorCol++;
    if (_cursorCol >= _cols) {
        _cursorCol = 0;
        [self moveToNextLine];
    }
}

- (void)moveToNextLine {
    _cursorRow++;
    if (_cursorRow >= _rows) {
        [self scrollUpOneLine];
        _cursorRow = _rows - 1;
    }
}

- (void)scrollUpOneLine {
    memmove(_cells, _cells + _cols, sizeof(ZBCell) * (size_t)_cols * (size_t)(_rows - 1));
    [self clearLine:_rows - 1 from:0 to:_cols - 1];
    for (int row = 0; row < _rows - 1; row++) {
        [self markRowDirty:row];
    }
}

- (void)clearLine:(int)row from:(int)start to:(int)end {
    if (row < 0 || row >= _rows) return;
    start = MAX(0, start);
    end = MIN(_cols - 1, end);
    for (int col = start; col <= end; col++) {
        ZBCell *cell = &_cells[row * _cols + col];
        if (cell->ch != ' ' || cell->fg != 1 || cell->bold) {
            cell->ch = ' ';
            cell->fg = 1;
            cell->bold = NO;
            cell->dirty = YES;
        }
    }
}

- (void)clearScreen {
    for (int row = 0; row < _rows; row++) {
        [self clearLine:row from:0 to:_cols - 1];
    }
}

- (void)eraseCharacters:(int)count {
    count = MAX(1, count);
    [self clearLine:_cursorRow from:_cursorCol to:MIN(_cols - 1, _cursorCol + count - 1)];
}

- (void)insertCharacters:(int)count {
    count = MIN(MAX(1, count), _cols - _cursorCol);
    ZBCell *row = &_cells[_cursorRow * _cols];
    memmove(&row[_cursorCol + count], &row[_cursorCol], sizeof(ZBCell) * (size_t)(_cols - _cursorCol - count));
    [self clearLine:_cursorRow from:_cursorCol to:_cursorCol + count - 1];
    [self markRowDirty:_cursorRow];
}

- (void)deleteCharacters:(int)count {
    count = MIN(MAX(1, count), _cols - _cursorCol);
    ZBCell *row = &_cells[_cursorRow * _cols];
    memmove(&row[_cursorCol], &row[_cursorCol + count], sizeof(ZBCell) * (size_t)(_cols - _cursorCol - count));
    [self clearLine:_cursorRow from:_cols - count to:_cols - 1];
    [self markRowDirty:_cursorRow];
}

- (void)insertLines:(int)count {
    count = MIN(MAX(1, count), _rows - _cursorRow);
    size_t rowSize = sizeof(ZBCell) * (size_t)_cols;
    memmove(&_cells[(_cursorRow + count) * _cols],
            &_cells[_cursorRow * _cols],
            rowSize * (size_t)(_rows - _cursorRow - count));
    for (int row = _cursorRow; row < _cursorRow + count; row++) {
        [self clearLine:row from:0 to:_cols - 1];
    }
    for (int row = _cursorRow; row < _rows; row++) {
        [self markRowDirty:row];
    }
}

- (void)deleteLines:(int)count {
    count = MIN(MAX(1, count), _rows - _cursorRow);
    size_t rowSize = sizeof(ZBCell) * (size_t)_cols;
    memmove(&_cells[_cursorRow * _cols],
            &_cells[(_cursorRow + count) * _cols],
            rowSize * (size_t)(_rows - _cursorRow - count));
    for (int row = _rows - count; row < _rows; row++) {
        [self clearLine:row from:0 to:_cols - 1];
    }
    for (int row = _cursorRow; row < _rows; row++) {
        [self markRowDirty:row];
    }
}

- (NSArray<NSNumber *> *)currentCSIParameters {
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    int value = -1;
    _csiPrivate = NO;

    for (size_t i = 0; i < _csiLen; i++) {
        char c = _csi[i];
        if (c == '?') {
            _csiPrivate = YES;
            continue;
        }
        if (c >= '0' && c <= '9') {
            if (value < 0) value = 0;
            value = value * 10 + (c - '0');
        } else if (c == ';') {
            [values addObject:@(value)];
            value = -1;
        }
    }

    if (value >= 0 || values.count > 0) {
        [values addObject:@(value)];
    }

    return values;
}

- (int)csiValue:(NSArray<NSNumber *> *)params index:(NSUInteger)index defaultValue:(int)defaultValue {
    if (index >= params.count) return defaultValue;
    int value = params[index].intValue;
    return value < 0 ? defaultValue : value;
}

- (unichar)characterAtColumn:(int)col row:(int)row {
    if (col < 0 || col >= _cols || row < 0 || row >= _rows) return ' ';
    unichar ch = _cells[row * _cols + col].ch;
    return ch ? ch : ' ';
}

- (BOOL)isDigitAtColumn:(int)col row:(int)row {
    unichar ch = [self characterAtColumn:col row:row];
    return ch >= '0' && ch <= '9';
}

- (BOOL)isLikelyMapCellAtColumn:(int)col row:(int)row {
    (void)row;
    return col >= 10;
}

- (BOOL)isFloorDotAtColumn:(int)col row:(int)row {
    if (![self isLikelyMapCellAtColumn:col row:row]) return NO;

    /* Keep decimal points in item weights and character stats crisp. */
    if ([self isDigitAtColumn:col - 1 row:row] || [self isDigitAtColumn:col + 1 row:row]) {
        return NO;
    }

    return YES;
}

- (NSColor *)terrainDotColorForCell:(ZBCell)cell {
    switch (cell.fg) {
        case 3:
        case 11:
            return _sandColor;
        case 5:
        case 13:
            return _grassColor;
        case 7:
        case 15:
            return _dirtColor;
        case 8:
            return _rockColor;
        default:
            return _floorColor;
    }
}

- (NSColor *)renderColorForCell:(ZBCell)cell column:(int)col row:(int)row {
    unichar ch = cell.ch ? cell.ch : ' ';

    if ([self isLikelyMapCellAtColumn:col row:row]) {
        switch (ch) {
            case '.':
                if ([self isFloorDotAtColumn:col row:row]) {
                    return [self terrainDotColorForCell:cell];
                }
                break;
            case '%':
                if (cell.fg == 10) return _treePurpleColor;
                return _treeColor;
            case ':':
                return _rockColor;
            case '#':
                return _wallColor;
            case ';':
                return _swampColor;
            case '~':
                if (cell.fg == 4 || cell.fg == 12) return _lavaColor;
                if (cell.fg == 5 || cell.fg == 13) return _acidColor;
                return _waterColor;
            default:
                break;
        }
    }

    return _colors[MIN((NSUInteger)cell.fg, _colors.count - 1)];
}

- (void)handleCSI:(char)final {
    NSArray<NSNumber *> *params = [self currentCSIParameters];

    switch (final) {
        case 'H':
        case 'f': {
            int row = [self csiValue:params index:0 defaultValue:1] - 1;
            int col = [self csiValue:params index:1 defaultValue:1] - 1;
            _cursorRow = MIN(MAX(row, 0), _rows - 1);
            _cursorCol = MIN(MAX(col, 0), _cols - 1);
            break;
        }
        case 'G': {
            int col = [self csiValue:params index:0 defaultValue:1] - 1;
            _cursorCol = MIN(MAX(col, 0), _cols - 1);
            break;
        }
        case 'A':
            _cursorRow = MAX(0, _cursorRow - [self csiValue:params index:0 defaultValue:1]);
            break;
        case 'B':
            _cursorRow = MIN(_rows - 1, _cursorRow + [self csiValue:params index:0 defaultValue:1]);
            break;
        case 'C':
            _cursorCol = MIN(_cols - 1, _cursorCol + [self csiValue:params index:0 defaultValue:1]);
            break;
        case 'D':
            _cursorCol = MAX(0, _cursorCol - [self csiValue:params index:0 defaultValue:1]);
            break;
        case 'E':
            _cursorRow = MIN(_rows - 1, _cursorRow + [self csiValue:params index:0 defaultValue:1]);
            _cursorCol = 0;
            break;
        case 'F':
            _cursorRow = MAX(0, _cursorRow - [self csiValue:params index:0 defaultValue:1]);
            _cursorCol = 0;
            break;
        case 'd': {
            int row = [self csiValue:params index:0 defaultValue:1] - 1;
            _cursorRow = MIN(MAX(row, 0), _rows - 1);
            break;
        }
        case 'J': {
            int mode = [self csiValue:params index:0 defaultValue:0];
            if (mode == 2 || mode == 3) {
                [self clearScreen];
            } else if (mode == 0) {
                [self clearLine:_cursorRow from:_cursorCol to:_cols - 1];
                for (int row = _cursorRow + 1; row < _rows; row++) [self clearLine:row from:0 to:_cols - 1];
            } else if (mode == 1) {
                for (int row = 0; row < _cursorRow; row++) [self clearLine:row from:0 to:_cols - 1];
                [self clearLine:_cursorRow from:0 to:_cursorCol];
            }
            break;
        }
        case 'K': {
            int mode = [self csiValue:params index:0 defaultValue:0];
            if (mode == 0) [self clearLine:_cursorRow from:_cursorCol to:_cols - 1];
            else if (mode == 1) [self clearLine:_cursorRow from:0 to:_cursorCol];
            else if (mode == 2) [self clearLine:_cursorRow from:0 to:_cols - 1];
            break;
        }
        case 'm':
            [self handleSGR:params];
            break;
        case 'X':
            [self eraseCharacters:[self csiValue:params index:0 defaultValue:1]];
            break;
        case '@':
            [self insertCharacters:[self csiValue:params index:0 defaultValue:1]];
            break;
        case 'P':
            [self deleteCharacters:[self csiValue:params index:0 defaultValue:1]];
            break;
        case 'L':
            [self insertLines:[self csiValue:params index:0 defaultValue:1]];
            break;
        case 'M':
            [self deleteLines:[self csiValue:params index:0 defaultValue:1]];
            break;
        case 'S': {
            int count = [self csiValue:params index:0 defaultValue:1];
            int oldRow = _cursorRow;
            _cursorRow = 0;
            [self deleteLines:count];
            _cursorRow = oldRow;
            break;
        }
        case 'T': {
            int count = [self csiValue:params index:0 defaultValue:1];
            int oldRow = _cursorRow;
            _cursorRow = 0;
            [self insertLines:count];
            _cursorRow = oldRow;
            break;
        }
        case 's':
            _savedCursorCol = _cursorCol;
            _savedCursorRow = _cursorRow;
            break;
        case 'u':
            _cursorCol = MIN(MAX(_savedCursorCol, 0), _cols - 1);
            _cursorRow = MIN(MAX(_savedCursorRow, 0), _rows - 1);
            break;
        case 'h':
        case 'l':
            if (_csiPrivate) {
                for (NSNumber *number in params) {
                    int code = number.intValue;
                    if (code == 47 || code == 1047 || code == 1049) {
                        _cursorCol = 0;
                        _cursorRow = 0;
                        [self clearScreen];
                    }
                }
            }
            break;
        default:
            break;
    }
}

- (void)handleSGR:(NSArray<NSNumber *> *)params {
    if (params.count == 0) {
        _fg = 1;
        _bold = NO;
        return;
    }

    for (NSNumber *number in params) {
        int code = number.intValue;
        if (code < 0 || code == 0) {
            _fg = 1;
            _bold = NO;
        } else if (code == 1) {
            _bold = YES;
        } else if (code == 22) {
            _bold = NO;
        } else if (code == 39) {
            _fg = 1;
        } else if (code >= 30 && code <= 37) {
            static const uint8_t map[8] = {0, 9, 5, 11, 6, 10, 14, 1};
            _fg = map[code - 30];
        } else if (code >= 90 && code <= 97) {
            static const uint8_t map[8] = {8, 12, 13, 11, 14, 10, 14, 9};
            _fg = map[code - 90];
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedRed:0.025 green:0.028 blue:0.026 alpha:1.0] setFill];
    NSRectFill(dirtyRect);

    NSRect terminalRect = [self terminalRect];
    if (!NSIntersectsRect(dirtyRect, terminalRect)) {
        return;
    }

    [[NSColor blackColor] setFill];
    NSRectFill(NSIntersectionRect(dirtyRect, terminalRect));

    [[NSColor colorWithCalibratedRed:0.18 green:0.21 blue:0.20 alpha:1.0] setStroke];
    NSFrameRect(terminalRect);

    NSMutableString *run = [NSMutableString stringWithCapacity:(NSUInteger)_cols];
    NSMutableDictionary<NSAttributedStringKey, id> *attrs = [@{ NSFontAttributeName: _font } mutableCopy];

    for (int row = 0; row < _rows; row++) {
        NSRect rowRect = NSMakeRect(_contentX,
                                    _contentY + (CGFloat)row * _cellHeight,
                                    (CGFloat)_cols * _cellWidth,
                                    _cellHeight);
        if (!NSIntersectsRect(dirtyRect, rowRect)) continue;

        int col = 0;
        while (col < _cols) {
            ZBCell first = _cells[row * _cols + col];
            NSColor *runColor = [self renderColorForCell:first column:col row:row];
            [run setString:@""];
            int startCol = col;

            while (col < _cols) {
                ZBCell cell = _cells[row * _cols + col];
                if (cell.fg != first.fg || cell.bold != first.bold) break;
                NSColor *cellColor = [self renderColorForCell:cell column:col row:row];
                if (cellColor != runColor) break;
                unichar ch = cell.ch ? cell.ch : ' ';
                [run appendFormat:@"%C", ch];
                col++;
            }

            attrs[NSForegroundColorAttributeName] = runColor;
            attrs[NSFontAttributeName] = first.bold ? _boldFont : _font;

            [run drawAtPoint:NSMakePoint(_contentX + (CGFloat)startCol * _cellWidth,
                                         _contentY + (CGFloat)row * _cellHeight + _baselineOffset)
              withAttributes:attrs];

            for (int cleanCol = startCol; cleanCol < col; cleanCol++) {
                _cells[row * _cols + cleanCol].dirty = NO;
            }
        }
    }

    _needsFullRedraw = NO;
}

@end

@interface ZBAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ZBAppDelegate {
    NSWindow *_window;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    NSRect frame = NSMakeRect(0, 0, 1120, 720);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable |
                                                     NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Zangband";
    _window.minSize = NSMakeSize(860, 560);
    _window.contentView = [[ZBTerminalView alloc] initWithFrame:frame];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

static void ZBInstallMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Zangband"];
    NSString *quitTitle = @"Quit Zangband";
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New Game" action:@selector(newGame:) keyEquivalent:@"n"]];
    [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Restart" action:@selector(restartGame:) keyEquivalent:@"r"]];
    fileItem.submenu = fileMenu;

    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewItem];

    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Bigger Text" action:@selector(increaseFontSize:) keyEquivalent:@"+"]];
    [viewMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Smaller Text" action:@selector(decreaseFontSize:) keyEquivalent:@"-"]];
    [viewMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Actual Size" action:@selector(resetFontSize:) keyEquivalent:@"0"]];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]];
    viewItem.submenu = viewMenu;

    NSApp.mainMenu = mainMenu;
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        ZBInstallMainMenu();

        ZBAppDelegate *delegate = [[ZBAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }

    return 0;
}
