//
//  CuplivoISHKernel.h
//  Runner
//
//  Objective-C wrapper around the embedded iSH-ARM64 kernel for the Cuplivo
//  Linux sandbox. Boots exactly once per app process (become_first_process
//  is irreversible); the rootfs is shared by all workspaces and host
//  directories are exposed to the guest via fakefs bind mounts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a guest process that is init or a direct
/// child of init exits. userInfo: @{@"pid": NSNumber, @"code": NSNumber}.
extern NSNotificationName const CuplivoISHProcessExitedNotification;

@interface CuplivoISHKernel : NSObject

+ (instancetype)shared;

/// Whether the kernel has been booted (and the fakefs rootfs mounted).
@property (nonatomic, readonly) BOOL isBooted;

/// The rootfs root path (containing data/ + meta.db) the kernel booted
/// with, or nil before boot.
@property (nonatomic, readonly, nullable) NSString *bootRootPath;

/// Boot the kernel and mount the fakefs rootfs at [rootPath]/data.
/// Idempotent: returns 0 immediately if already booted. Returns 0 on
/// success, a negative errno-style code on failure. Must be called from a
/// background thread (the calling thread becomes guest PID 1).
- (int)bootWithRootPath:(NSString *)rootPath;

/// Bind-mount a host directory onto a guest path (fakefs_bind_mount).
/// Re-mounting the same guest path with a different host path rebinds it.
/// The kernel must be booted. Returns 0 on success, negative on failure.
- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath;

/// Remove a bind mount previously created with bindMountPath:toHostPath:.
- (int)bindUnmountPath:(NSString *)linuxPath;

@end

NS_ASSUME_NONNULL_END
