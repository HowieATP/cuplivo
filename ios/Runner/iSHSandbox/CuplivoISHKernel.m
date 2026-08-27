//
//  CuplivoISHKernel.m
//  Runner
//
//  Boot sequence adapted from OpenMinis/MinisApp ISHKernel.m (GPL-3.0, see
//  ios/sandbox/NOTICE), stripped of app-specific offloads and hooks.
//

#import "CuplivoISHKernel.h"
#import "CuplivoISHCrashGuards.h"

// SCDynamicStore (what `scutil --dns` uses) is macOS-only. For change
// watching we use SCNetworkReachability — the well-known iOS substitute —
// because Network.framework's NWPathMonitor cannot be declared on this
// toolchain: `@import Network;` resolves but provides no declarations, and
// Network/nw_path_monitor.h does not exist in the Xcode 26.x iOS SDK.
@import SystemConfiguration;

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fake.h"
#include "ish/fs/tty.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/fs/path.h"
#include "ish/fs/fd.h"

#include <pthread.h>
#include <stdio.h>
#include <sys/syslimits.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>

NSNotificationName const CuplivoISHProcessExitedNotification = @"CuplivoISHProcessExited";

static NSString *const kDnsSubdir = @"CuplivoSandbox/dns";
static NSString *const kNodeFetchPolyfillResource = @"node-fetch-jitless-polyfill";
static NSString *const kNodeFetchPolyfillGuestPath = @"/lib/cuplivo-fetch-jitless-polyfill.js";
static NSString *const kNodeFetchPolyfillGuestTempPath =
    @"/lib/.cuplivo-fetch-jitless-polyfill.js.tmp";

// Fallback nameservers appended after the system resolver servers. System
// DNS may be absent (airplane mode) or unusable from the guest (a loopback
// resolver belongs to the host, see -isUsableDnsServer:). Public servers
// only — the fallback is never user-configurable in v1 (issue #463).
static const char *kPublicDns[] = {"1.1.1.1", "8.8.8.8", "223.5.5.5"};

// Exit hook exposed by kernel/task.c.
extern void (*exit_hook)(struct task *task, int code);

#pragma mark - Console TTY driver

// Init's stdio goes to a console TTY whose output is discarded: sandbox
// commands run with pipe-based stdio (CuplivoISHExecutor), the console only
// exists so PID 1 has valid fds.
static int cuplivo_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void)tty;
    (void)buf;
    (void)blocking;
    return (int)len;
}

static int cuplivo_tty_init(struct tty *tty) {
    (void)tty;
    return 0;
}

static void cuplivo_tty_cleanup(struct tty *tty) {
    (void)tty;
}

static struct tty_driver_ops cuplivo_console_ops = {
    .init = cuplivo_tty_init,
    .write = cuplivo_tty_write,
    .cleanup = cuplivo_tty_cleanup,
};

DEFINE_TTY_DRIVER(cuplivo_console_driver, &cuplivo_console_ops, TTY_CONSOLE_MAJOR, 8);

#pragma mark - Process exit handler

static void cuplivo_handle_process_exit(struct task *task, int code) {
    // Only notify for init (parent == NULL) and direct children of init
    // (parent->parent == NULL) — mirrors OpenMinis and avoids pids_lock
    // contention with sys_wait4.
    if (task->parent != NULL && task->parent->parent != NULL)
        return;
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:CuplivoISHProcessExitedNotification
                          object:nil
                        userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

#pragma mark - CuplivoISHKernel

@implementation CuplivoISHKernel {
    BOOL _isBooted;
    NSString *_rootPath;
    NSString *_dataPath;
    NSString *_dnsHostPath;
    SCNetworkReachabilityRef _dnsReachability;
}

- (void)dealloc {
    if (_dnsReachability != NULL) {
        SCNetworkReachabilitySetDispatchQueue(_dnsReachability, NULL);
        CFRelease(_dnsReachability);
    }
}

+ (instancetype)shared {
    static CuplivoISHKernel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CuplivoISHKernel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isBooted = NO;
    }
    return self;
}

- (BOOL)isBooted {
    return _isBooted;
}

- (NSString *)bootRootPath {
    return _rootPath;
}

- (int)bootWithRootPath:(NSString *)rootPath {
    if (_isBooted) {
        NSLog(@"CuplivoISHKernel: already booted");
        return 0;
    }

    int err;

    // 0. Crash containment before any guest code runs.
    CuplivoISHInstallCrashGuards();
    CuplivoISHInstallDieGuard();

    // 1. Mount the root filesystem (fakefs: data/ + meta.db).
    _rootPath = rootPath;
    _dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    err = mount_root(&fakefs, _dataPath.fileSystemRepresentation);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: mount_root failed: %d", err);
        _rootPath = nil;
        _dataPath = nil;
        return err;
    }
    NSLog(@"CuplivoISHKernel: root filesystem mounted at %@", _dataPath);

    // Register the canonical host path of the rootfs data dir so fakefs can
    // suppress self-containing bind mounts (see fake.c).
    char canonical_data_path[PATH_MAX];
    if (realpath(_dataPath.fileSystemRepresentation, canonical_data_path) != NULL) {
        fakefs_set_rootfs_data_path(canonical_data_path);
    } else {
        NSLog(@"CuplivoISHKernel: realpath(data) failed (errno=%d), bind-mount cycle guard disabled", errno);
    }

    // 2. Become init process (PID 1). Irreversible for this process.
    err = become_first_process();
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: become_first_process failed: %d", err);
        return err;
    }
    current->thread = pthread_self();
    NSLog(@"CuplivoISHKernel: init process created (PID 1)");

    // 3. Device nodes.
    [self createDeviceNodes];

    // Node runs with --jitless in iSH, which removes WebAssembly and makes
    // Node 22's undici fetch crash while loading its llhttp WASM parser.
    // Install the bundled non-WASM fetch implementation before commands run.
    [self installNodeJitlessFetchPolyfill];

    // 4. Mount proc and devpts.
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"CuplivoISHKernel: /proc and /dev/pts mounted");

    // 5. DNS: /etc/resolv.conf as a file-level bind mount onto a host file
    // so it can be refreshed without touching meta.db.
    [self mountDnsConfig];

    // 6. Exit hook for command completion tracking.
    exit_hook = cuplivo_handle_process_exit;

    // 7. Console TTY + stdio for init.
    tty_drivers[TTY_CONSOLE_MAJOR] = &cuplivo_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: create_stdio failed: %d (non-fatal)", err);
    }

    _isBooted = YES;
    NSLog(@"CuplivoISHKernel: kernel initialized");
    return 0;
}

- (void)createDeviceNodes {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    NSLog(@"CuplivoISHKernel: device nodes created");
}

- (void)installNodeJitlessFetchPolyfill {
    NSURL *resource = [[NSBundle mainBundle]
        URLForResource:kNodeFetchPolyfillResource withExtension:@"js"];
    if (resource == nil) {
        NSLog(@"CuplivoISHKernel: node fetch polyfill bundle resource missing");
        return;
    }

    NSError *readError = nil;
    NSData *contents = [NSData dataWithContentsOfURL:resource
                                              options:0
                                                error:&readError];
    if (contents == nil) {
        NSLog(@"CuplivoISHKernel: node fetch polyfill read failed: %@", readError);
        return;
    }
    if (contents.length == 0) {
        NSLog(@"CuplivoISHKernel: node fetch polyfill bundle resource is empty");
        return;
    }

    struct fd *fd = generic_open(kNodeFetchPolyfillGuestTempPath.UTF8String,
                                 O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd)) {
        NSLog(@"CuplivoISHKernel: node fetch polyfill guest temp write open failed: %ld",
              PTR_ERR(fd));
        return;
    }

    const char *bytes = contents.bytes;
    size_t offset = 0;
    const size_t length = contents.length;
    while (offset < length) {
        ssize_t written = fd->ops->write(fd, bytes + offset, length - offset);
        if (written <= 0) {
            NSLog(@"CuplivoISHKernel: node fetch polyfill guest write failed: %zd",
                  written);
            break;
        }
        offset += (size_t)written;
    }
    fd_close(fd);

    if (offset != length) {
        int unlinkErr = generic_unlinkat(AT_PWD, kNodeFetchPolyfillGuestTempPath.UTF8String);
        if (unlinkErr < 0) {
            NSLog(@"CuplivoISHKernel: node fetch polyfill temp cleanup failed: %d", unlinkErr);
        }
        return;
    }

    int renameErr = generic_renameat(AT_PWD,
                                     kNodeFetchPolyfillGuestTempPath.UTF8String,
                                     AT_PWD,
                                     kNodeFetchPolyfillGuestPath.UTF8String);
    if (renameErr < 0) {
        NSLog(@"CuplivoISHKernel: node fetch polyfill guest install rename failed: %d",
              renameErr);
        int unlinkErr = generic_unlinkat(AT_PWD, kNodeFetchPolyfillGuestTempPath.UTF8String);
        if (unlinkErr < 0) {
            NSLog(@"CuplivoISHKernel: node fetch polyfill temp cleanup failed: %d", unlinkErr);
        }
        return;
    }

    NSLog(@"CuplivoISHKernel: installed node fetch polyfill");
}

- (void)mountDnsConfig {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dnsDir = [library stringByAppendingPathComponent:kDnsSubdir];
    _dnsHostPath = [dnsDir stringByAppendingPathComponent:@"resolv.conf"];

    if (![fm fileExistsAtPath:dnsDir]) {
        [fm createDirectoryAtPath:dnsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // Always rewrite (not seed-if-missing): heals stale/partial files from
    // older installs and picks up the current network before the mount.
    [self refreshDnsConfig];

    int err = fakefs_bind_mount("/etc/resolv.conf", _dnsHostPath.fileSystemRepresentation, false);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: DNS bind mount failed (%d) — writing through VFS", err);
        struct task *prev = current;
        current = pid_get_task(1);
        if (current) {
            NSString *seed = [self dnsContentString];
            struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
            if (!IS_ERR(fd)) {
                fd->ops->write(fd, seed.UTF8String, [seed lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                fd_close(fd);
            }
        }
        current = prev;
        return;
    }
    NSLog(@"CuplivoISHKernel: DNS bind mount OK: /etc/resolv.conf -> %@", _dnsHostPath);
    [self startDnsWatcher];
}

// System resolver servers, filtered, followed by the fallback list.
- (NSString *)dnsContentString {
    NSMutableArray<NSString *> *servers = [NSMutableArray array];
    void (^addServer)(NSString *) = ^(NSString *raw) {
        NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0 || [servers containsObject:s]) return;
        [servers addObject:s];
    };

    // On iOS, configd maintains the host /etc/resolv.conf, reflecting the
    // resolver configuration for the current network (Wi-Fi, cellular, VPN
    // on-demand...). SCDynamicStore (what `scutil --dns` uses) is macOS-only.
    FILE *resolv = fopen("/etc/resolv.conf", "r");
    if (resolv != NULL) {
        char line[512];
        while (fgets(line, sizeof(line), resolv) != NULL) {
            char ns[256];
            if (sscanf(line, "nameserver %255s", ns) == 1) {
                NSString *server = [NSString stringWithUTF8String:ns];
                if ([self isUsableDnsServer:server]) addServer(server);
            }
        }
        fclose(resolv);
    } else {
        NSLog(@"CuplivoISHKernel: /etc/resolv.conf unreadable — fallback DNS only");
    }

    // Always append the fallback: musl rotates through nameservers, so a
    // temporarily unreachable system server falls through to the public one.
    for (size_t i = 0; i < sizeof(kPublicDns) / sizeof(kPublicDns[0]); i++) {
        addServer([NSString stringWithUTF8String:kPublicDns[i]]);
    }

    NSMutableString *content = [NSMutableString string];
    for (NSString *server in servers) {
        [content appendFormat:@"nameserver %@\n", server];
    }
    return content;
}

// Valid IP address, not host-loopback. A VPN/ad-block app commonly points
// the system resolver at 127.0.0.1 (its local DNS proxy); from inside the
// guest's own emulated network stack that loopback means the guest itself,
// so such servers must be dropped. LAN/private-range servers are kept — the
// guest shares the host's L3 connectivity and can reach them.
- (BOOL)isUsableDnsServer:(NSString *)server {
    struct in_addr addr4;
    if (inet_pton(AF_INET, server.UTF8String, &addr4) == 1) {
        const uint8_t *bytes = (const uint8_t *)&addr4;
        return bytes[0] != 127;
    }
    struct in6_addr addr6;
    if (inet_pton(AF_INET6, server.UTF8String, &addr6) == 1) {
        return memcmp(&addr6, &in6addr_loopback, sizeof(addr6)) != 0;
    }
    return NO;
}

- (void)refreshDnsConfig {
    if (_dnsHostPath == nil) return;
    NSString *content = [self dnsContentString];
    NSError *error = nil;
    if (![content writeToFile:_dnsHostPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"CuplivoISHKernel: DNS refresh write failed: %@", error);
        return;
    }
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    lines = [lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSLog(@"CuplivoISHKernel: refreshed host resolv.conf (%lu nameservers): %@",
          (unsigned long)lines.count, [lines componentsJoinedByString:@" | "]);
}

static void CuplivoDnsReachabilityChanged(SCNetworkReachabilityRef target,
                                          SCNetworkReachabilityFlags flags,
                                          void *info) {
    (void)target;
    (void)flags;
    @autoreleasepool {
        CuplivoISHKernel *kernel = (__bridge CuplivoISHKernel *)info;
        dispatch_async(dispatch_get_main_queue(), ^{
            [kernel refreshDnsConfig];
        });
    }
}

// Watch the network connectivity and rewrite the host file, so the guest's
// bind-mounted /etc/resolv.conf follows Wi-Fi <-> cellular switches and VPN
// connect/disconnect without an app relaunch. SCNetworkReachability fires on
// exactly those state transitions; DNS-only changes on the same link are not
// reported on iOS, so a relaunch still rewrites the config at boot. The API
// is deprecated as of iOS 17.4 (replaced by Network.framework), but the
// Network.framework module cannot be imported on the current Xcode 26.x SDK.
- (void)startDnsWatcher {
    if (_dnsReachability != NULL) return;
    SCNetworkReachabilityRef reachability =
        SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, "1.1.1.1");
    if (reachability == NULL) {
        NSLog(@"CuplivoISHKernel: SCNetworkReachabilityCreateWithName failed — DNS watcher disabled");
        return;
    }
    SCNetworkReachabilityContext context = {.version = 0,
                                            .info = (__bridge void *)self,
                                            .retain = NULL,
                                            .release = NULL,
                                            .copyDescription = NULL};
    if (!SCNetworkReachabilitySetCallback(reachability, CuplivoDnsReachabilityChanged, &context)) {
        NSLog(@"CuplivoISHKernel: SCNetworkReachabilitySetCallback failed");
        CFRelease(reachability);
        return;
    }
    if (!SCNetworkReachabilitySetDispatchQueue(reachability, dispatch_get_main_queue())) {
        NSLog(@"CuplivoISHKernel: SCNetworkReachabilitySetDispatchQueue failed");
        CFRelease(reachability);
        return;
    }
    _dnsReachability = reachability;
    NSLog(@"CuplivoISHKernel: DNS watcher active (SCNetworkReachability)");
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath {
    if (!_isBooted) {
        NSLog(@"CuplivoISHKernel: bindMount failed — kernel not booted");
        return -1;
    }
    int err = fakefs_bind_mount(linuxPath.fileSystemRepresentation,
                                hostPath.fileSystemRepresentation, false);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: bindMount %@ -> %@ failed: %d", linuxPath, hostPath, err);
    }
    return err;
}

- (int)bindUnmountPath:(NSString *)linuxPath {
    if (!_isBooted) {
        return -1;
    }
    return fakefs_bind_unmount(linuxPath.fileSystemRepresentation);
}

@end
