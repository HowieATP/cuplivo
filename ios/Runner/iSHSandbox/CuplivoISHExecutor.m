//
//  CuplivoISHExecutor.m
//  Runner
//
//  Adapted from OpenMinis/MinisApp ISHShellExecutor.m (GPL-3.0, see
//  ios/sandbox/NOTICE), reduced to one-shot capture execution: no line
//  callbacks, no stdin feeding, result delivered as a single dictionary.
//

#import "CuplivoISHExecutor.h"
#import "CuplivoISHKernel.h"

#include "ish/kernel/init.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/task.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/fs.h"
#include "ish/fs/devices.h"
#include "ish/fs/real.h"
#include "ish/fs/path.h"
#include "ish/fs/stat.h"

#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <sys/stat.h>
#include <string.h>

/// Native per-stream capture cap; keep only a head/tail preview after this
/// limit while continuing to drain the pipe.
enum {
    kMaxStreamBytes = 64 * 1024,
    kHeadStreamBytes = 32 * 1024,
    kTailStreamBytes = 32 * 1024,
};
/// Grace period for readers to drain pipes after process exit.
static const NSTimeInterval kDrainGraceSeconds = 1.0;
/// Grace period for the exit notification to arrive after a timeout kill.
static const NSTimeInterval kKillGraceSeconds = 2.0;
/// Bounded wait for readers to honour the abort request and exit. A reader
/// notices the flag within one 500 ms poll cycle; the extra headroom covers
/// final drain work and scheduler delays under load.
static const NSTimeInterval kReaderJoinSeconds = 1.5;
static const char *kNodeFetchPolyfillGuestPath =
    "/lib/cuplivo-fetch-jitless-polyfill.js";

static BOOL CuplivoGuestFileExists(const char *path) {
    struct fd *fd = generic_open(path, O_RDONLY_, 0);
    if (IS_ERR(fd)) return NO;
    fd_close(fd);
    return YES;
}

#pragma mark - Execution context

@class CuplivoISHBoundedData;

@interface CuplivoISHExecutionContext : NSObject {
    int _stdoutReadEnd;  // owned by the stdout reader task once adopted
    int _stderrReadEnd;  // owned by the stderr reader task once adopted
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic) int guestPid;
@property (nonatomic) pid_t_ guestPgid;
@property (nonatomic, readonly) CuplivoISHBoundedData *stdoutData;
@property (nonatomic, readonly) CuplivoISHBoundedData *stderrData;
@property (nonatomic, readonly) dispatch_semaphore_t waitSemaphore;
@property (nonatomic, readonly) dispatch_group_t readersGroup;
@property (atomic) int exitCode;
@property (atomic) BOOL exited;
@property (atomic) BOOL cancelled;
@property (atomic) BOOL stdoutReaderDone;
@property (atomic) BOOL stderrReaderDone;
/// Owned by the reader task: the exec thread asks readers to stop via these
/// flags instead of closing descriptors out from under them (issue #397).
/// Readers poll with a 500 ms timeout, so a flag is honoured within one
/// poll cycle; the reader then closes its own read end before reporting
/// done.
@property (atomic) BOOL stdoutAbort;
@property (atomic) BOOL stderrAbort;

- (int *)stdoutPipe;
- (int *)stderrPipe;
/// Ownership transfer of a pipe read end from runCommand to its reader task.
/// After this call only the owning reader may close that descriptor.
- (void)adoptReadEnd:(int)fd isStdErr:(BOOL)isStdErr;
/// Close the reader-owned read end exactly once. Must only be called by the
/// reader that adopted the end, after it left its poll/read loop.
- (void)closeOwnedReadEnd:(BOOL)isStdErr;
@end

@interface CuplivoISHBoundedData : NSObject
@property (nonatomic, readonly) BOOL truncated;
- (void)appendBytes:(const void *)bytes length:(NSUInteger)length;
- (NSData *)dataForDecoding;
@end

/// Number of trailing bytes to drop so [data] ends on a UTF-8 boundary. The
/// head slice of a truncated stream can cut a multi-byte sequence in half;
/// without this the assembled NSData is invalid UTF-8 and decodeStream would
/// fall back to Latin-1, garbling the entire non-ASCII output.
static NSUInteger CuplivoUTF8HeadTrimLength(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    if (len == 0) return 0;
    NSUInteger i = len;
    while (i > 0 && (bytes[i - 1] & 0xC0) == 0x80) {
        i--;
    }
    NSUInteger trailingContinuations = len - i;
    if (i == 0) return trailingContinuations;
    uint8_t lead = bytes[i - 1];
    NSUInteger expected;
    if ((lead & 0x80) == 0) {
        expected = 1; // ASCII: complete 1-byte sequence
    } else if ((lead & 0xE0) == 0xC0) {
        expected = (lead >= 0xC2) ? 2 : 0; // 0xC0/0xC1 are invalid leads
    } else if ((lead & 0xF0) == 0xE0) {
        expected = 3;
    } else if ((lead & 0xF8) == 0xF0) {
        expected = 4;
    } else {
        expected = 0;
    }
    if (expected == 0 || trailingContinuations + 1 < expected) {
        return trailingContinuations + 1; // invalid/incomplete: drop it all
    }
    return 0; // complete trailing sequence: nothing to drop
}

/// Number of leading bytes to drop so [data] starts on a UTF-8 boundary. The
/// tail slice of a truncated stream can start inside a multi-byte sequence;
/// the leading continuation bytes belong to the dropped prefix.
static NSUInteger CuplivoUTF8TailTrimStart(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    NSUInteger i = 0;
    while (i < len && (bytes[i] & 0xC0) == 0x80) {
        i++;
    }
    return i;
}

@implementation CuplivoISHBoundedData {
    NSMutableData *_fullData;
    NSMutableData *_headData;
    uint8_t _tail[kTailStreamBytes];
    NSUInteger _tailStart;
    NSUInteger _tailSize;
    NSUInteger _totalBytes;
}

- (instancetype)init {
    if (self = [super init]) {
        _fullData = [NSMutableData dataWithCapacity:kMaxStreamBytes];
        _headData = [NSMutableData dataWithCapacity:kHeadStreamBytes];
    }
    return self;
}

- (void)appendBytes:(const void *)bytes length:(NSUInteger)length {
    if (length == 0) return;
    // Reader threads append on the concurrent reader queue while the exec
    // thread may decode; @synchronized keeps the fallback decode path free
    // of data races.
    @synchronized (self) {
        const uint8_t *source = (const uint8_t *)bytes;
        NSUInteger previousBytes = _totalBytes;
        _totalBytes += length;

        if (_fullData != nil) {
            if (previousBytes <= kMaxStreamBytes && length <= kMaxStreamBytes - previousBytes) {
                [_fullData appendBytes:source length:length];
            } else {
                _fullData = nil;
            }
        }

        NSUInteger headRemaining = kHeadStreamBytes - _headData.length;
        if (headRemaining > 0) {
            [_headData appendBytes:source length:MIN(headRemaining, length)];
        }

        if (length >= kTailStreamBytes) {
            memcpy(_tail, source + length - kTailStreamBytes, kTailStreamBytes);
            _tailStart = 0;
            _tailSize = kTailStreamBytes;
            return;
        }
        if (_tailSize + length <= kTailStreamBytes) {
            [self copyBytes:source length:length toCircularOffset:(_tailStart + _tailSize) % kTailStreamBytes];
            _tailSize += length;
            return;
        }
        NSUInteger overflow = _tailSize + length - kTailStreamBytes;
        NSUInteger oldStart = _tailStart;
        NSUInteger oldSize = _tailSize;
        _tailStart = (oldStart + overflow) % kTailStreamBytes;
        _tailSize = kTailStreamBytes;
        [self copyBytes:source length:length toCircularOffset:(oldStart + oldSize) % kTailStreamBytes];
    }
}

- (void)copyBytes:(const uint8_t *)source
           length:(NSUInteger)length
toCircularOffset:(NSUInteger)offset {
    NSUInteger first = MIN(length, kTailStreamBytes - offset);
    memcpy(_tail + offset, source, first);
    if (first < length) {
        memcpy(_tail, source + first, length - first);
    }
}

- (BOOL)truncated {
    @synchronized (self) {
        return _totalBytes > kMaxStreamBytes;
    }
}

- (NSData *)tailData {
    @synchronized (self) {
        if (_tailSize == 0) return [NSData data];
        NSMutableData *data = [NSMutableData dataWithCapacity:_tailSize];
        NSUInteger first = MIN(_tailSize, kTailStreamBytes - _tailStart);
        [data appendBytes:_tail + _tailStart length:first];
        if (first < _tailSize) {
            [data appendBytes:_tail length:_tailSize - first];
        }
        return data;
    }
}

- (NSData *)dataForDecoding {
    @synchronized (self) {
        if (!self.truncated) return _fullData ?: [NSData data];
        NSData *head = _headData;
        NSData *tail = [self tailData];
        NSUInteger headTrim = CuplivoUTF8HeadTrimLength(head);
        NSUInteger tailTrim = CuplivoUTF8TailTrimStart(tail);
        NSMutableData *data = [NSMutableData dataWithCapacity:kMaxStreamBytes + 64];
        if (head.length - headTrim > 0) {
            [data appendBytes:head.bytes length:head.length - headTrim];
        }
        static const char marker[] = "\n...[output truncated]...\n";
        [data appendBytes:marker length:sizeof(marker) - 1];
        if (tail.length - tailTrim > 0) {
            [data appendBytes:tail.bytes + tailTrim length:tail.length - tailTrim];
        }
        return data;
    }
}

@end

@implementation CuplivoISHExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        _stdoutData = [[CuplivoISHBoundedData alloc] init];
        _stderrData = [[CuplivoISHBoundedData alloc] init];
        _waitSemaphore = dispatch_semaphore_create(0);
        _readersGroup = dispatch_group_create();
        _stdoutPipe[0] = _stdoutPipe[1] = -1;
        _stderrPipe[0] = _stderrPipe[1] = -1;
        _stdoutReadEnd = _stderrReadEnd = -1;
        _exitCode = -1;
    }
    return self;
}

- (void)adoptReadEnd:(int)fd isStdErr:(BOOL)isStdErr {
    // Exec thread only, before the owning reader has been enqueued: no
    // concurrent access to the slots yet. Moving the descriptor out of the
    // generic pipe array and into the dedicated read-end slot makes the
    // ownership change explicit in state — after adoption closePipeEnds
    // cannot even see this fd.
    @synchronized (self) {
        if (isStdErr) {
            _stderrReadEnd = fd;
            _stderrPipe[0] = -1;
        } else {
            _stdoutReadEnd = fd;
            _stdoutPipe[0] = -1;
        }
    }
}

- (void)closeOwnedReadEnd:(BOOL)isStdErr {
    // Reader-side only: runs on the reader's dispatch queue after its
    // poll/read loop has ended. The exec thread never touches this fd once
    // it was adopted, so this close cannot race another thread's use of the
    // descriptor. Resetting the slot under the same lock keeps every
    // mutation of the ownership slots serialized.
    int fd;
    @synchronized (self) {
        fd = isStdErr ? _stderrReadEnd : _stdoutReadEnd;
        if (isStdErr) {
            _stderrReadEnd = -1;
        } else {
            _stdoutReadEnd = -1;
        }
    }
    if (fd >= 0) {
        close(fd);
    }
}

/// Close every pipe endpoint still recorded on this context.
///
/// Callers must guarantee that no concurrent reader owns one of the listed
/// descriptors. That holds on the early setup-failure paths in runCommand
/// (before any reader is started) and in dealloc (the last strong reference
/// is gone, which includes the reader blocks). Adopted read ends are moved
/// out of the generic arrays into reader-owned slots and are cleared by the
/// owning reader itself, so this method never closes a descriptor that
/// another thread is still polling, reading, or about to close (issue #397).
- (void)closePipeEnds {
    @synchronized (self) {
        if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
        if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
        if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
        if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
        _stdoutPipe[0] = _stdoutPipe[1] = -1;
        _stderrPipe[0] = _stderrPipe[1] = -1;
        // Reader-owned read-end slots are deliberately not touched here:
        // they are either already -1 (the reader closed its own end) or
        // still owned by a live reader that will close them.
    }
}

- (void)dealloc {
    [self closePipeEnds];
}

@end

#pragma mark - Executor

@implementation CuplivoISHExecutor

static NSMutableDictionary<NSNumber *, CuplivoISHExecutionContext *> *_activeExecutions;
static NSMutableDictionary<NSString *, CuplivoISHExecutionContext *> *_activeExecutionsByRequest;
static NSMutableSet<NSString *> *_cancelledRequests;
static NSMutableSet<NSString *> *_queuedRequests;
static dispatch_queue_t _execQueue;
static dispatch_queue_t _readerQueue;

+ (void)initialize {
    if (self == [CuplivoISHExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        _activeExecutionsByRequest = [NSMutableDictionary dictionary];
        _cancelledRequests = [NSMutableSet set];
        _queuedRequests = [NSMutableSet set];
        _execQueue = dispatch_queue_create("com.cuplivo.ish.exec", DISPATCH_QUEUE_SERIAL);
        _readerQueue = dispatch_queue_create("com.cuplivo.ish.reader", DISPATCH_QUEUE_CONCURRENT);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:CuplivoISHProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (void)executeCommand:(NSString *)command
              requestId:(NSString *)requestId
                   cwd:(NSString *)cwd
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSString *effectiveRequestId = requestId.length > 0
        ? [requestId copy]
        : [NSString stringWithFormat:@"ios_shell_%@", [NSUUID UUID].UUIDString];
    @synchronized (_activeExecutions) {
        [_queuedRequests addObject:effectiveRequestId];
    }
    dispatch_async(_execQueue, ^{
        // Keep the requestId in _queuedRequests until runCommand has either
        // registered the active context or returned. This closes the cancel
        // window between queue pop and active registration: cancelRequest:
        // always finds the id in one of the two sets, so a cancel issued
        // during command setup is recorded and honoured instead of dropped.
        BOOL earlyCancelled = NO;
        @synchronized (_activeExecutions) {
            if ([_cancelledRequests containsObject:effectiveRequestId]) {
                [_cancelledRequests removeObject:effectiveRequestId];
                [_queuedRequests removeObject:effectiveRequestId];
                earlyCancelled = YES;
            }
        }
        if (earlyCancelled) {
            // Invoke the completion outside the lock: the callback could
            // re-enter cancelRequest/cancelAll which synchronize on the
            // same mutex.
            completion([self cancelledResult]);
            return;
        }
        NSDictionary *result = [self runCommand:command
                                       requestId:effectiveRequestId
                                             cwd:cwd
                                         timeout:timeout];
        @synchronized (_activeExecutions) {
            [_queuedRequests removeObject:effectiveRequestId];
        }
        completion(result);
    });
}

+ (BOOL)cancelRequest:(NSString *)requestId {
    if (requestId.length == 0) return NO;
    CuplivoISHExecutionContext *ctx = nil;
    int pid = -1;
    BOOL recorded = NO;
    @synchronized (_activeExecutions) {
        ctx = _activeExecutionsByRequest[requestId];
        if (ctx) {
            ctx.cancelled = YES;
            pid = ctx.guestPid;
            recorded = YES;
        } else if ([_queuedRequests containsObject:requestId]) {
            // Only remember cancellation for requests that have already been
            // registered by executeCommand. Unknown IDs may belong to the
            // Dart-side rootfs installer, which does not use this executor.
            [_cancelledRequests addObject:requestId];
            recorded = YES;
        }
    }
    if (ctx && pid > 1) {
        [self killProcessGroup:pid groupId:ctx.guestPgid];
        dispatch_semaphore_signal(ctx.waitSemaphore);
        return YES;
    }
    // A queued cancellation was recorded and will be honoured by the queued
    // block or the registration gate; report success so callers do not
    // interpret it as a miss.
    return recorded;
}

+ (void)cancelAll {
    NSArray<CuplivoISHExecutionContext *> *active;
    @synchronized (_activeExecutions) {
        active = [_activeExecutionsByRequest allValues];
        [_cancelledRequests addObjectsFromArray:_queuedRequests.allObjects];
        [_queuedRequests removeAllObjects];
        for (CuplivoISHExecutionContext *ctx in active) {
            ctx.cancelled = YES;
        }
    }
    for (CuplivoISHExecutionContext *ctx in active) {
        if (ctx.guestPid > 1) {
            [self killProcessGroup:ctx.guestPid groupId:ctx.guestPgid];
            dispatch_semaphore_signal(ctx.waitSemaphore);
        }
    }
}

#pragma mark - Execution core

+ (NSDictionary *)runCommand:(NSString *)command
                    requestId:(NSString *)requestId
                          cwd:(nullable NSString *)cwd
                      timeout:(NSTimeInterval)timeout {
    @synchronized (_activeExecutions) {
        if ([_cancelledRequests containsObject:requestId]) {
            [_cancelledRequests removeObject:requestId];
            return [self cancelledResult];
        }
    }
    if (![CuplivoISHKernel shared].isBooted) {
        return [self errorResult:@"kernel not booted"];
    }
    timeout = MAX(0.001, MIN(timeout, 3600.0));

    CuplivoISHExecutionContext *ctx = [[CuplivoISHExecutionContext alloc] init];
    ctx.requestId = requestId;

    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        [ctx closePipeEnds];
        NSLog(@"CuplivoISHExecutor: pipe() failed: %s", strerror(errno));
        return [self errorResult:[NSString stringWithFormat:@"pipe failed: %s", strerror(errno)]];
    }

    struct task *saved_current = current;

    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        NSLog(@"CuplivoISHExecutor: become_new_init_child failed: %d", err);
        return [self errorResult:[NSString stringWithFormat:@"become_new_init_child failed: %d", err]];
    }

    struct task *task = current;

    // stdin: /dev/null.
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd) {
        int real_fd = open("/dev/null", O_RDONLY);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:[NSString stringWithFormat:@"open /dev/null failed: %s", strerror(errno)]];
        }
        stdin_fd->real_fd = real_fd;
        task->files->files[0] = stdin_fd;
    }

    // stdout/stderr: pipes.
    struct fd *stdout_fd = adhoc_fd_create(&realfs_fdops);
    if (stdout_fd) {
        int real_fd = dup([ctx stdoutPipe][1]);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:@"dup(stdout) failed"];
        }
        stdout_fd->real_fd = real_fd;
        task->files->files[1] = stdout_fd;
    }
    struct fd *stderr_fd = adhoc_fd_create(&realfs_fdops);
    if (stderr_fd) {
        int real_fd = dup([ctx stderrPipe][1]);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:@"dup(stderr) failed"];
        }
        stderr_fd->real_fd = real_fd;
        task->files->files[2] = stderr_fd;
    }
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    // Write-end ownership: after this point the guest task (via the dup'ed
    // real fds in files[1]/files[2]) holds the only write ends; this thread
    // tracks neither end anymore. The read ends stay open here and are
    // handed to the reader tasks below.
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // Guest cwd (defaults to / set by inherit; apply requested cwd).
    if (cwd.length > 0) {
        struct statbuf st;
        int statErr = generic_statat(AT_PWD, cwd.UTF8String, &st, true);
        if (statErr < 0 || !(st.mode & S_IFDIR)) {
            current = saved_current;
            NSLog(@"CuplivoISHExecutor: cwd %@ not a directory (err=%d)", cwd, statErr);
            return [self errorResult:[NSString stringWithFormat:@"cwd not found: %@", cwd]];
        }
        struct fd *dir = generic_open(cwd.UTF8String, O_RDONLY_, 0);
        if (IS_ERR(dir)) {
            current = saved_current;
            return [self errorResult:[NSString stringWithFormat:@"cwd open failed: %ld", PTR_ERR(dir)]];
        }
        fs_chdir(task->fs, dir);
    }

    // argv: /bin/sh -c "<command>\n". busybox ash heredocs need the
    // trailing newline after the terminator (OpenMinis T-heredoc fix).
    NSString *normalized = [command hasSuffix:@"\n"] ? command : [command stringByAppendingString:@"\n"];
    NSArray<NSString *> *argvArray = @[@"/bin/sh", @"-c", normalized];
    char argv_buf[16384];
    size_t pos = 0;
    int exec_argc = 0;
    for (NSString *arg in argvArray) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len >= sizeof(argv_buf) - 1) {
            current = saved_current;
            return [self errorResult:@"argv too long"];
        }
        memcpy(argv_buf + pos, str, len);
        pos += len;
        exec_argc++;
    }
    argv_buf[pos] = '\0';

    // envp: NUL-separated, double-NUL terminated.
    char envp_buf[8192];
    size_t envp_pos = 0;
#define ENVP_APPEND(s) do { \
    const char *_s = (s); \
    size_t _len = strlen(_s) + 1; \
    if (envp_pos + _len < sizeof(envp_buf) - 256) { \
        memcpy(envp_buf + envp_pos, _s, _len); \
        envp_pos += _len; \
    } \
} while (0)

    ENVP_APPEND("TERM=xterm-256color");
    ENVP_APPEND("HOME=/root");
    ENVP_APPEND("PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    ENVP_APPEND("LANG=C.UTF-8");
    ENVP_APPEND("CHARSET=UTF-8");
    ENVP_APPEND("DEBIAN_FRONTEND=noninteractive");
    ENVP_APPEND("GIT_TERMINAL_PROMPT=0");
    ENVP_APPEND("NO_COLOR=1");
    ENVP_APPEND("PYTHONMALLOC=malloc");
    ENVP_APPEND("PYTHONDONTWRITEBYTECODE=1");
    // V8 cannot JIT under emulation. --no-experimental-fetch prevents Node
    // 22 from loading undici's WASM llhttp parser; when the bundled fallback
    // is present, it restores fetch through core http/https instead.
    if (CuplivoGuestFileExists(kNodeFetchPolyfillGuestPath)) {
        ENVP_APPEND("NODE_OPTIONS=--jitless --no-experimental-fetch "
                    "--require=/lib/cuplivo-fetch-jitless-polyfill.js "
                    "--max-old-space-size=512");
    } else {
        NSLog(@"CuplivoISHExecutor: node fetch polyfill unavailable; "
              "disabling built-in fetch to avoid undici WASM crash");
        ENVP_APPEND("NODE_OPTIONS=--jitless --no-experimental-fetch "
                    "--max-old-space-size=512");
    }
    // Go tuning (ported from OpenMinis): cap the scheduler to one core-pair
    // so it does not spin extra threads under the interpreter, and disable
    // async preemption which is expensive under emulation.
    ENVP_APPEND("GOMAXPROCS=2");
    ENVP_APPEND("GODEBUG=asyncpreemptoff=1");
    // OpenMinis also injects ENV=/etc/profile and node LD_PRELOAD=/lib/zero_free.so;
    // both are intentionally omitted here pending rootfs confirmation (#361).

    // Device timezone for musl (POSIX TZ with fixed name; +/- abbreviations
    // confuse musl's parser — OpenMinis approach).
    {
        NSTimeZone *tz = [NSTimeZone systemTimeZone];
        NSInteger secs = tz.secondsFromGMT;
        NSInteger hrs = secs / 3600;
        NSInteger mins = labs(secs % 3600) / 60;
        NSString *posixTZ;
        if (mins != 0) {
            posixTZ = [NSString stringWithFormat:@"LCL%+ld:%02ld", (long)-hrs, (long)mins];
        } else {
            posixTZ = [NSString stringWithFormat:@"LCL%+ld", (long)-hrs];
        }
        NSString *tzEnv = [NSString stringWithFormat:@"TZ=%@", posixTZ];
        ENVP_APPEND(tzEnv.UTF8String);
    }
    envp_buf[envp_pos] = '\0';
#undef ENVP_APPEND

    err = do_execve("/bin/sh", exec_argc, argv_buf, envp_buf);
    if (err < 0) {
        current = saved_current;
        NSLog(@"CuplivoISHExecutor: do_execve failed: %d", err);
        return [self errorResult:[NSString stringWithFormat:@"do_execve failed: %d", err]];
    }

    ctx.guestPid = task->pid;
    ctx.guestPgid = task->group->pgid;
    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
        _activeExecutionsByRequest[requestId] = ctx;
        if ([_cancelledRequests containsObject:requestId]) {
            [_cancelledRequests removeObject:requestId];
            ctx.cancelled = YES;
            // A cancel recorded while this context was not yet registered
            // could not signal the semaphore; wake the waiter so the kill
            // path below runs immediately instead of blocking for the full
            // timeout.
            dispatch_semaphore_signal(ctx.waitSemaphore);
        }
    }

    task_start(task);
    current = saved_current;

    // Hand ownership of both read ends to the reader tasks. From here on the
    // exec thread must not close these descriptors: each reader closes its
    // own read end when its poll/read loop ends (issue #397). adoptReadEnd:
    // also moves the fd out of the generic pipe arrays, so closePipeEnds
    // cannot reach an adopted descriptor even defensively.
    int stdoutReadFd = [ctx stdoutPipe][0];
    int stderrReadFd = [ctx stderrPipe][0];
    [ctx adoptReadEnd:stdoutReadFd isStdErr:NO];
    [self startReaderForPipe:stdoutReadFd context:ctx isStdErr:NO];
    [ctx adoptReadEnd:stderrReadFd isStdErr:YES];
    [self startReaderForPipe:stderrReadFd context:ctx isStdErr:YES];

    // Wait for exit or timeout.
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    long waitResult = dispatch_semaphore_wait(ctx.waitSemaphore, waitTime);

    BOOL timedOut = NO;
    BOOL cancelled = ctx.cancelled;
    if (waitResult != 0 || cancelled) {
        timedOut = !cancelled;
        [self killProcessGroup:ctx.guestPid groupId:ctx.guestPgid];
        // Give the exit notification a chance to land so the exit code and
        // any partial output are captured.
        (void)dispatch_semaphore_wait(ctx.waitSemaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKillGraceSeconds * NSEC_PER_SEC)));
    }

    // Let readers drain remaining pipe data before decoding. This must be a
    // completion wait, not a polling loop on _execQueue: the latter made the
    // next shell command wait in 50ms increments after every exit.
    BOOL readersDrained = dispatch_group_wait(
        ctx.readersGroup,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDrainGraceSeconds * NSEC_PER_SEC))) == 0;

    // A guest child that inherited the pipes keeps the write ends open, so
    // the readers stay blocked after the shell task exited. Reap those
    // descendants first: their fds close, the readers hit EOF and terminate
    // on their own.
    if (ctx.exited || !readersDrained) {
        // The shell may already have exited while a background child either
        // owns the pipe or redirected its output elsewhere. Keep the original
        // process-group id so that child is still terminated after the shell
        // PID disappears.
        [self killProcessGroup:ctx.guestPid groupId:ctx.guestPgid];
    }
    // Last resort: ask the readers to stop instead of closing descriptors
    // under them. Cross-thread close() neither safely cancels another
    // thread's poll()/read() nor prevents the fd number from being reopened
    // and misread by a still-running reader (issue #397). After adoptReadEnd:
    // the read ends are out of the generic pipe arrays, so a last-resort
    // closePipeEnds could not reach them anyway — the abort flags are the
    // only remaining unblocking mechanism. They are honoured within one
    // 500 ms poll cycle; kReaderJoinSeconds bounds the join wait. If a
    // reader somehow misses it (stuck in read(2) on a guest pipe that stays
    // open), its own read end stays valid because only that reader ever
    // closes it — final cleanup below leaves the slot alone.
    if (!ctx.stdoutReaderDone || !ctx.stderrReaderDone) {
        ctx.stdoutAbort = YES;
        ctx.stderrAbort = YES;
        NSDate *joinDeadline = [NSDate dateWithTimeIntervalSinceNow:kReaderJoinSeconds];
        while ((!ctx.stdoutReaderDone || !ctx.stderrReaderDone) &&
               [joinDeadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.05];
        }
        readersDrained = ctx.stdoutReaderDone && ctx.stderrReaderDone;
    }
    if (!readersDrained) {
        NSLog(@"CuplivoISHExecutor: reader(s) still alive for request %@ "
              "(stdout=%d stderr=%d); decoding captured data anyway",
              requestId, ctx.stdoutReaderDone, ctx.stderrReaderDone);
    }

    @synchronized(_activeExecutions) {
        [_activeExecutions removeObjectForKey:@(ctx.guestPid)];
        [_activeExecutionsByRequest removeObjectForKey:requestId];
    }
    // No explicit close of reader-owned read ends here: each reader closes
    // (or has already closed) its own read end, so closing again from this
    // thread would either be a double close or — for a reader that missed
    // the abort window — a close of an fd that thread is still using. The
    // host write ends were already closed right after dup'ing into the
    // guest task, and every earlier failure path returns while no reader
    // exists, leaving cleanup to dealloc's closePipeEnds. ctx drops out of
    // the registries here; ARC releases it once the last strong reference
    // (including the reader blocks) is gone, and dealloc runs closePipeEnds
    // as the single final sweep.
    return @{
        @"exitCode": @(timedOut || cancelled ? -1 : ctx.exitCode),
        @"stdout": [self decodeStream:ctx.stdoutData],
        @"stderr": [self decodeStream:ctx.stderrData],
        @"timedOut": @(timedOut),
        @"cancelled": @(cancelled),
        @"stdoutTruncated": @([ctx.stdoutData truncated]),
        @"stderrTruncated": @([ctx.stderrData truncated]),
    };
}

+ (NSDictionary *)errorResult:(NSString *)reason {
    NSLog(@"CuplivoISHExecutor: %@", reason);
    return @{
        @"exitCode": @(-1),
        @"stdout": @"",
        @"stderr": reason,
        @"timedOut": @NO,
        @"cancelled": @NO,
        @"stdoutTruncated": @NO,
        @"stderrTruncated": @NO,
        @"error": reason,
    };
}

+ (NSDictionary *)cancelledResult {
    return @{
        @"exitCode": @(-1),
        @"stdout": @"",
        @"stderr": @"",
        @"timedOut": @NO,
        @"cancelled": @YES,
        @"stdoutTruncated": @NO,
        @"stderrTruncated": @NO,
    };
}

+ (NSString *)decodeStream:(CuplivoISHBoundedData *)stream {
    NSData *data = [stream dataForDecoding];
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

#pragma mark - Process exit handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    CuplivoISHExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
    }
    if (!ctx) return;

    ctx.exitCode = exitCode;
    ctx.exited = YES;
    // Wake the executor as soon as the process exits. It separately waits on
    // readersGroup with a bounded drain grace, so every successful command no
    // longer pays an unconditional 200ms latency tax.
    dispatch_semaphore_signal(ctx.waitSemaphore);
}

#pragma mark - Pipe reading

+ (void)startReaderForPipe:(int)fd context:(CuplivoISHExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    dispatch_group_enter(ctx.readersGroup);
    dispatch_async(_readerQueue, ^{
        [self readPipe:fd context:ctx isStdErr:isStdErr];
        dispatch_group_leave(ctx.readersGroup);
    });
}

/// Drain one pipe read end until EOF, an error, or an abort request.
///
/// The reader owns the descriptor passed in (ownership was handed over via
/// adoptReadEnd:isStdErr: right before startReaderForPipe:) and is the only
/// thread that may close it. It does so after leaving the poll/read loop and
/// before marking the stream done, so ReaderDone implies "read end closed"
/// and no other code path can close this fd concurrently or after a number
/// reuse (issue #397).
+ (void)readPipe:(int)fd context:(CuplivoISHExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[4096];
    CuplivoISHBoundedData *out = isStdErr ? ctx.stderrData : ctx.stdoutData;
    struct pollfd pfd = {.fd = fd, .events = POLLIN};

    for (;;) {
        // Abort is checked once per 500 ms poll cycle; the exec thread sets
        // it only after the normal drain grace elapsed, so latency here does
        // not affect output capture in the common case.
        if (isStdErr ? ctx.stderrAbort : ctx.stdoutAbort) break;
        int pr = poll(&pfd, 1, 500);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) {
            // EOF once the guest closed its end; after exit + grace the
            // caller stops using the buffer anyway.
            if (ctx.exited) break;
            continue;
        }
        if ((pfd.revents & (POLLHUP | POLLERR)) && !(pfd.revents & POLLIN)) {
            break;
        }
        ssize_t bytesRead = read(fd, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            [out appendBytes:buffer length:(NSUInteger)bytesRead];
        } else if (bytesRead == 0) {
            break; // EOF
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
    }
    // Close our own read end first, then publish done-ness: once
    // stdout/stderrReaderDone is observed, the descriptor is guaranteed to
    // be closed by us already, and nobody else will touch it.
    [ctx closeOwnedReadEnd:isStdErr];
    if (isStdErr) {
        ctx.stderrReaderDone = YES;
    } else {
        ctx.stdoutReaderDone = YES;
    }
}

#pragma mark - Kill

static void CuplivoSignalThreadGroup(struct tgroup *group, int signal,
                                     struct siginfo_ info) {
    struct task *task;
    list_for_each_entry(&group->threads, task, group_links) {
        send_signal(task, signal, info);
    }
}

/// Signals descendants that moved to a different process group. The original
/// group is handled separately, so this avoids signalling its tasks twice.
static void CuplivoSignalTaskTreeOutsideProcessGroup(
    struct task *task, pid_t_ pgid, int signal, struct siginfo_ info) {
    if (task->group->pgid != pgid && task_is_leader(task)) {
        CuplivoSignalThreadGroup(task->group, signal, info);
    }
    struct task *child;
    list_for_each_entry(&task->children, child, siblings) {
        CuplivoSignalTaskTreeOutsideProcessGroup(child, pgid, signal, info);
    }
}

/// Signal all threads in a process group directly through iSH's pgroup list.
/// Scanning the whole 32K PID table under pids_lock made timeout/cancellation
/// stalls proportional to the maximum PID instead of the command's process
/// tree size.
static void CuplivoSignalProcessGroup(pid_t_ pgid, int signal, struct siginfo_ info) {
    struct pid *groupPid = pid_get((dword_t)pgid);
    if (groupPid == NULL) return;

    struct tgroup *group;
    list_for_each_entry(&groupPid->pgroup, group, pgroup) {
        CuplivoSignalThreadGroup(group, signal, info);
    }
}

/// SIGTERM the process group (pgid match or ancestry), then SIGKILL
/// survivors after a short delay. Ported from OpenMinis including the
/// pid-recycle safety rails. When the root shell has already exited, the
/// process group remains a safe identity while any inherited child survives;
/// kill those members immediately with SIGKILL and do not schedule a delayed
/// PID-based pass.
+ (void)killProcessGroup:(int)pid groupId:(pid_t_)knownPgid {
    if (pid <= 1 && knownPgid <= 1) {
        NSLog(@"CuplivoISHExecutor: refusing killProcessGroup for pid=%d pgid=%d",
              pid, knownPgid);
        return;
    }
    struct siginfo_ info = SIGINFO_NIL;

    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = rootTask ? rootTask->group->pgid : knownPgid;
    if (pgid <= 1) {
        unlock(&pids_lock);
        return;
    }
    int immediateSignal = rootTask ? SIGTERM_ : SIGKILL_;
    CuplivoSignalProcessGroup(pgid, immediateSignal, info);
    if (rootTask != NULL) {
        CuplivoSignalTaskTreeOutsideProcessGroup(rootTask, pgid,
                                                  immediateSignal, info);
    }
    unlock(&pids_lock);

    // Without the root task there is no safe object identity for a delayed
    // PID-recycle check. The immediate group pass above is enough because a
    // still-running child keeps this process group from being reused.
    if (rootTask == NULL) {
        return;
    }

    int capturedPid = pid;
    struct task *capturedRoot = rootTask;
    pid_t_ capturedPgid = pgid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(0, 0), ^{
        lock(&pids_lock);
        struct task *still = pid_get_task((dword_t)capturedPid);
        if (still != capturedRoot) {
            unlock(&pids_lock);
            return;
        }
        if (capturedPgid != 0) {
            CuplivoSignalProcessGroup(capturedPgid, SIGKILL_, info);
        }
        CuplivoSignalTaskTreeOutsideProcessGroup(still, capturedPgid,
                                                  SIGKILL_, info);
        unlock(&pids_lock);
    });
}

@end
