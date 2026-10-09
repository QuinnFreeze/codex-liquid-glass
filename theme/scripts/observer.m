#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const CodexBundleID = @"com.openai.codex";

static BOOL ShouldObserve(NSString *bundleID, pid_t pid, NSString *bundlePath) {
    return [bundleID isEqualToString:CodexBundleID] && pid > 0 &&
           bundlePath.length > 0 && bundlePath.isAbsolutePath;
}

static BOOL ClaimPID(NSMutableSet<NSNumber *> *seen, pid_t pid) {
    NSNumber *key = @(pid);
    if ([seen containsObject:key]) return NO;
    [seen addObject:key];
    return YES;
}

static void ForgetPID(NSMutableSet<NSNumber *> *seen, pid_t pid) {
    [seen removeObject:@(pid)];
}

static NSArray<NSString *> *AttachmentArguments(NSString *root, NSString *appPath, pid_t pid) {
    return @[[root stringByAppendingPathComponent:@"scripts/auto-attach.py"],
             @"--app", appPath, @"--pid", [NSString stringWithFormat:@"%d", pid]];
}

static NSArray<NSString *> *MaintenanceArguments(NSString *root, NSString *reason) {
    return @[[root stringByAppendingPathComponent:@"scripts/dock-repair.py"], @"--reason", reason];
}

static BOOL QueueMaintenanceOnce(NSMutableArray<NSDictionary *> *queue) {
    for (NSDictionary *item in queue) {
        if ([item[@"kind"] isEqualToString:@"maintenance"]) return NO;
    }
    [queue addObject:@{@"kind": @"maintenance"}];
    return YES;
}

static NSDictionary *FileStampFromStat(const struct stat *value) {
    return @{@"device": @((unsigned long long)value->st_dev),
             @"inode": @((unsigned long long)value->st_ino),
             @"seconds": @((long long)value->st_mtimespec.tv_sec),
             @"nanoseconds": @((long long)value->st_mtimespec.tv_nsec),
             @"size": @((long long)value->st_size)};
}

static NSDictionary *FileStamp(NSString *path) {
    struct stat value;
    return stat(path.fileSystemRepresentation, &value) == 0 ? FileStampFromStat(&value) : nil;
}

static BOOL SameFileIdentity(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil &&
           [left[@"device"] isEqual:right[@"device"]] && [left[@"inode"] isEqual:right[@"inode"]];
}

@interface ThemeObserver : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSString *python;
@property(nonatomic, strong) NSFileHandle *log;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenPIDs;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic, strong) NSTask *activeTask;
@property(nonatomic, strong) id launchToken;
@property(nonatomic, strong) id terminationToken;
@property(nonatomic, strong) dispatch_source_t terminateSource;
@property(nonatomic, strong) dispatch_source_t interruptSource;
@property(nonatomic, strong) dispatch_source_t dockFileSource;
@property(nonatomic, strong) dispatch_source_t dockDirectorySource;
@property(nonatomic, strong) dispatch_source_t maintenanceDebounce;
@property(nonatomic, strong) dispatch_source_t runtimeExitSource;
@property(nonatomic) pid_t watchedRuntimePID;
@property(nonatomic, strong) NSMutableArray<NSDate *> *runtimeRecoveries;
@property(nonatomic, copy) NSString *dockPreferencesPath;
@property(nonatomic, strong) NSDictionary *dockStamp;
@property(nonatomic, strong) NSDictionary *watchedFileStamp;
@property(nonatomic, strong) NSMutableSet<NSString *> *maintenanceReasons;
@property(nonatomic, strong) NSMutableDictionary<NSString *, dispatch_block_t> *delayedChecks;
@property(nonatomic) BOOL shuttingDown;
- (BOOL)start:(NSError **)error;
@end

@implementation ThemeObserver

- (void)watchRuntime {
    if (self.shuttingDown) return;
    NSString *path = [self.root stringByAppendingPathComponent:@"state/daemon.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    pid_t pid = [info isKindOfClass:NSDictionary.class] ? [info[@"pid"] intValue] : 0;
    if (pid <= 0 || pid == self.watchedRuntimePID) return;
    if (self.runtimeExitSource) dispatch_source_cancel(self.runtimeExitSource);
    self.watchedRuntimePID = pid;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                      DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    self.runtimeExitSource = source;
    __weak ThemeObserver *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        ThemeObserver *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.shuttingDown) return;
        dispatch_source_cancel(strongSelf.runtimeExitSource);
        strongSelf.runtimeExitSource = nil;
        strongSelf.watchedRuntimePID = 0;
        // Reapply deliberately stops the previous daemon. Let its replacement
        // settle before checking; attachment reuses a healthy replacement.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (strongSelf.shuttingDown || [[NSFileManager defaultManager]
                fileExistsAtPath:[strongSelf.root stringByAppendingPathComponent:@"state/autostart-disabled"]]) return;
            NSData *replacementData = [NSData dataWithContentsOfFile:
                [strongSelf.root stringByAppendingPathComponent:@"state/daemon.json"]];
            NSDictionary *replacement = replacementData ? [NSJSONSerialization JSONObjectWithData:
                replacementData options:0 error:NULL] : nil;
            pid_t replacementPID = [replacement isKindOfClass:NSDictionary.class] ? [replacement[@"pid"] intValue] : 0;
            if (replacementPID > 0 && replacementPID != pid && kill(replacementPID, 0) == 0) {
                [strongSelf watchRuntime];
                return;
            }
            NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-60];
            [strongSelf.runtimeRecoveries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDate *date, NSDictionary *bindings) {
                (void)bindings; return [date compare:cutoff] != NSOrderedAscending;
            }]];
            if (strongSelf.runtimeRecoveries.count >= 3) {
                [strongSelf writeLog:@"runtime recovery limited to 3 attempts per minute; inspect runtime.log"];
                return;
            }
            BOOL queuedRecovery = NO;
            for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
                if (!application.terminated && ShouldObserve(application.bundleIdentifier,
                    application.processIdentifier, application.bundleURL.path)) {
                    queuedRecovery = YES;
                    [strongSelf.queue addObject:@{@"kind": @"attachment", @"pid": @(application.processIdentifier),
                                                  @"app": application.bundleURL.path}];
                }
            }
            if (queuedRecovery) {
                [strongSelf.runtimeRecoveries addObject:NSDate.date];
                [strongSelf writeLog:@"runtime exited; checking attachment and recovering if necessary"];
                [strongSelf drainQueue];
            }
        });
    });
    dispatch_resume(source);
}

- (void)writeLog:(NSString *)message {
    NSString *line = [NSString stringWithFormat:@"[%@] observer: %@\n", [NSDate date], message];
    @try {
        [self.log writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) {
        // A logging failure must not start/stop Codex or remove an applied theme.
        fprintf(stderr, "codex-theme-observer: unable to append diagnostic log\n");
    }
}

- (void)drainQueue {
    if (self.shuttingDown || self.activeTask != nil || self.queue.count == 0) return;
    NSDictionary *item = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    BOOL maintenance = [item[@"kind"] isEqualToString:@"maintenance"];
    pid_t pid = [item[@"pid"] intValue];
    NSString *appPath = item[@"app"];
    NSArray<NSString *> *arguments;
    NSString *description;

    // A short-lived application may have quit while another attachment was running.
    if (maintenance) {
        // This job repairs the managed entry even when Codex has already exited.
        // The Python helper checks ownership and the uninstall marker before writes.
        NSString *reason = [[self.maintenanceReasons.allObjects sortedArrayUsingSelector:@selector(compare:)]
                            componentsJoinedByString:@","];
        [self.maintenanceReasons removeAllObjects];
        arguments = MaintenanceArguments(self.root, reason.length > 0 ? reason : @"queued-event");
        description = [NSString stringWithFormat:@"Dock maintenance reason=%@", reason];
    } else {
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (application == nil || application.terminated ||
            !ShouldObserve(application.bundleIdentifier, pid, application.bundleURL.path) ||
            ![application.bundleURL.path isEqualToString:appPath]) {
            [self writeLog:[NSString stringWithFormat:@"skip exited or replaced application pid=%d", pid]];
            [self drainQueue];
            return;
        }
        arguments = AttachmentArguments(self.root, appPath, pid);
        description = [NSString stringWithFormat:@"attachment pid=%d app=%@", pid, appPath];
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.python];
    // These brief launch/repair operations service an explicit app opening.
    // Avoid inheriting idle/background QoS for Python startup and preference I/O.
    task.qualityOfService = NSQualityOfServiceUserInitiated;
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:self.root isDirectory:YES];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = self.log;
    task.standardError = self.log;
    self.activeTask = task;
    __weak ThemeObserver *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ThemeObserver *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf writeLog:[NSString stringWithFormat:@"%@ finished status=%d",
                                 description, finished.terminationStatus]];
            strongSelf.activeTask = nil;
            [strongSelf watchRuntime];
            [strongSelf drainQueue];
        });
    };
    NSError *error = nil;
    [self writeLog:[NSString stringWithFormat:@"%@ started", description]];
    if (![task launchAndReturnError:&error]) {
        task.terminationHandler = nil;
        self.activeTask = nil;
        [self writeLog:[NSString stringWithFormat:@"%@ launch failed error=%@",
                       description, error.localizedDescription]];
        [self drainQueue];
    }
}

- (void)scheduleMaintenance:(NSString *)reason {
    if (self.shuttingDown) return;
    [self.maintenanceReasons addObject:reason];
    if (self.maintenanceDebounce == nil) {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                          dispatch_get_main_queue());
        self.maintenanceDebounce = source;
        __weak ThemeObserver *weakSelf = self;
        dispatch_source_set_event_handler(source, ^{
            ThemeObserver *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.shuttingDown) return;
            dispatch_source_cancel(strongSelf.maintenanceDebounce);
            strongSelf.maintenanceDebounce = nil;
            // A previously queued job may have consumed these reasons while
            // this debounce was waiting behind an attachment task.
            if (strongSelf.maintenanceReasons.count == 0) return;
            QueueMaintenanceOnce(strongSelf.queue);
            [strongSelf drainQueue];
        });
        dispatch_resume(source);
    }
    // A short, one-shot debounce; there is no idle polling or repeating timer.
    dispatch_source_set_timer(self.maintenanceDebounce,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)),
                              DISPATCH_TIME_FOREVER, 30 * NSEC_PER_MSEC);
}

- (void)scheduleDelayedMaintenance:(NSString *)reason after:(NSTimeInterval)delay {
    NSString *token = [NSUUID UUID].UUIDString;
    __weak ThemeObserver *weakSelf = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        ThemeObserver *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.shuttingDown) return;
        [strongSelf.delayedChecks removeObjectForKey:token];
        [strongSelf reconcileDockFile];
        [strongSelf scheduleMaintenance:reason];
    });
    self.delayedChecks[token] = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

- (void)installDockFileSource {
    if (self.dockFileSource != nil) {
        dispatch_source_cancel(self.dockFileSource);
        self.dockFileSource = nil;
    }
    self.watchedFileStamp = nil;
    int descriptor = open(self.dockPreferencesPath.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (descriptor < 0) return; // The parent-directory source detects a later creation.
    struct stat value;
    if (fstat(descriptor, &value) != 0) {
        close(descriptor);
        return;
    }
    self.watchedFileStamp = FileStampFromStat(&value);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB |
        DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if (source == nil) {
        close(descriptor);
        self.watchedFileStamp = nil;
        return;
    }
    self.dockFileSource = source;
    __weak ThemeObserver *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf reconcileDockFile]; });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    dispatch_resume(source);
}

- (void)reconcileDockFile {
    if (self.shuttingDown) return;
    NSDictionary *stamp = FileStamp(self.dockPreferencesPath);
    BOOL changed = !((stamp == nil && self.dockStamp == nil) || [stamp isEqual:self.dockStamp]);
    self.dockStamp = stamp;
    // Atomic preferences writes replace the inode. Rebind to the new file while
    // the parent source keeps watching the directory throughout the replacement.
    if (!SameFileIdentity(stamp, self.watchedFileStamp) &&
        (stamp != nil || self.dockFileSource != nil)) [self installDockFileSource];
    if (changed) [self scheduleMaintenance:@"dock-preference-change"];
}

- (void)startDockWatchers {
    self.dockPreferencesPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.apple.dock.plist"];
    self.dockStamp = FileStamp(self.dockPreferencesPath);
    [self installDockFileSource];
    NSString *directory = self.dockPreferencesPath.stringByDeletingLastPathComponent;
    int descriptor = open(directory.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (descriptor < 0) {
        [self writeLog:@"Dock preferences directory unavailable; lifecycle checks remain enabled"];
        return;
    }
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB |
        DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if (source == nil) {
        close(descriptor);
        [self writeLog:@"unable to watch Dock preferences directory; lifecycle checks remain enabled"];
        return;
    }
    self.dockDirectorySource = source;
    __weak ThemeObserver *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf reconcileDockFile]; });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    dispatch_resume(source);
}

- (void)stopObserving {
    self.shuttingDown = YES;
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    if (self.launchToken != nil) [center removeObserver:self.launchToken];
    if (self.terminationToken != nil) [center removeObserver:self.terminationToken];
    self.launchToken = nil;
    self.terminationToken = nil;
    for (dispatch_block_t block in self.delayedChecks.allValues) dispatch_block_cancel(block);
    [self.delayedChecks removeAllObjects];
    if (self.dockFileSource != nil) dispatch_source_cancel(self.dockFileSource);
    if (self.dockDirectorySource != nil) dispatch_source_cancel(self.dockDirectorySource);
    if (self.maintenanceDebounce != nil) dispatch_source_cancel(self.maintenanceDebounce);
    if (self.runtimeExitSource != nil) dispatch_source_cancel(self.runtimeExitSource);
    self.runtimeExitSource = nil;
    self.dockFileSource = nil;
    self.dockDirectorySource = nil;
    self.maintenanceDebounce = nil;
    [self.queue removeAllObjects];
    [self.maintenanceReasons removeAllObjects];
}

- (void)considerApplication:(NSRunningApplication *)application {
    pid_t pid = application.processIdentifier;
    NSString *appPath = application.bundleURL.path;
    if (application.terminated || !ShouldObserve(application.bundleIdentifier, pid, appPath)) return;
    if (!ClaimPID(self.seenPIDs, pid)) return;
    [self reconcileDockFile];
    [self scheduleMaintenance:@"codex-launch"];
    [self scheduleDelayedMaintenance:@"codex-launch-settled-2s" after:2];
    [self scheduleDelayedMaintenance:@"codex-launch-settled-8s" after:8];
    [self.queue addObject:@{@"kind": @"attachment", @"pid": @(pid), @"app": appPath}];
    [self drainQueue];
}

- (dispatch_source_t)exitSourceForSignal:(int)number {
    signal(number, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                      (uintptr_t)number, 0,
                                                      dispatch_get_main_queue());
    __weak ThemeObserver *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        ThemeObserver *strongSelf = weakSelf;
        [strongSelf writeLog:[NSString stringWithFormat:@"received signal=%d; exiting without changing Codex", number]];
        [strongSelf stopObserving];
        if (strongSelf.terminateSource != nil) dispatch_source_cancel(strongSelf.terminateSource);
        if (strongSelf.interruptSource != nil) dispatch_source_cancel(strongSelf.interruptSource);
        // Do not terminate Codex, the attachment task, or remove existing renderer styles.
        exit(0);
    });
    dispatch_resume(source);
    return source;
}

- (BOOL)start:(NSError **)error {
    NSString *state = [self.root stringByAppendingPathComponent:@"state"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:state
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions: @0700}
                                                       error:error]) return NO;
    NSString *logPath = [state stringByAppendingPathComponent:@"observer.log"];
    int descriptor = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        if (error != NULL) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    self.log = [[NSFileHandle alloc] initWithFileDescriptor:descriptor closeOnDealloc:YES];
    self.seenPIDs = [NSMutableSet set];
    self.queue = [NSMutableArray array];
    self.maintenanceReasons = [NSMutableSet set];
    self.delayedChecks = [NSMutableDictionary dictionary];
    self.runtimeRecoveries = [NSMutableArray array];
    self.terminateSource = [self exitSourceForSignal:SIGTERM];
    self.interruptSource = [self exitSourceForSignal:SIGINT];
    [self startDockWatchers];
    [self scheduleMaintenance:@"observer-start"];
    __weak ThemeObserver *weakSelf = self;
    // Register before the initial inventory so a launch during enumeration is deduplicated.
    self.launchToken = [[[NSWorkspace sharedWorkspace] notificationCenter]
                        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
        NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
        if ([application isKindOfClass:[NSRunningApplication class]]) {
            [weakSelf considerApplication:application];
        }
    }];
    self.terminationToken = [[[NSWorkspace sharedWorkspace] notificationCenter]
                             addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                             object:nil queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification *notification) {
        NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
        if (![application isKindOfClass:[NSRunningApplication class]] ||
            !ShouldObserve(application.bundleIdentifier, application.processIdentifier, application.bundleURL.path)) return;
        ThemeObserver *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        pid_t pid = application.processIdentifier;
        ForgetPID(strongSelf.seenPIDs, pid);
        // Discard stale queued work before this PID can be reused for another launch.
        NSIndexSet *stale = [strongSelf.queue indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return [item[@"kind"] isEqualToString:@"attachment"] && [item[@"pid"] intValue] == pid;
        }];
        [strongSelf.queue removeObjectsAtIndexes:stale];
        [strongSelf writeLog:[NSString stringWithFormat:@"application terminated pid=%d; released lifecycle deduplication", pid]];
        [strongSelf reconcileDockFile];
        [strongSelf scheduleMaintenance:@"codex-termination"];
    }];
    [self writeLog:@"started; watching NSWorkspace lifecycle and Dock preference vnode events"];
    for (NSRunningApplication *application in [NSWorkspace sharedWorkspace].runningApplications) {
        [self considerApplication:application];
    }
    return YES;
}

@end

// Exercises the real debounce/queue path without creating a subprocess or
// registering workspace/filesystem observers.
@interface ThemeObserverSelfTest : ThemeObserver
@property(nonatomic) NSUInteger drainCalls;
@end

@implementation ThemeObserverSelfTest
- (void)drainQueue { self.drainCalls++; }
@end

static int SelfTest(void) {
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    BOOL filter = ShouldObserve(CodexBundleID, 123, @"/Applications/ChatGPT.app") &&
                  !ShouldObserve(@"com.apple.finder", 123, @"/System/Library/CoreServices/Finder.app") &&
                  !ShouldObserve(CodexBundleID, 0, @"/Applications/ChatGPT.app") &&
                  !ShouldObserve(CodexBundleID, 123, @"relative.app") &&
                  !ShouldObserve(nil, 123, @"/Applications/ChatGPT.app");
    BOOL dedup = ClaimPID(seen, 123) && !ClaimPID(seen, 123) && ClaimPID(seen, 124);
    ForgetPID(seen, 123);
    BOOL pidReuse = ClaimPID(seen, 123) && !ClaimPID(seen, 124);
    NSArray *arguments = AttachmentArguments(@"/Users/test/Theme With Spaces", @"/Applications/ChatGPT.app", 123);
    NSArray *expected = @[@"/Users/test/Theme With Spaces/scripts/auto-attach.py", @"--app",
                          @"/Applications/ChatGPT.app", @"--pid", @"123"];
    BOOL command = [arguments isEqualToArray:expected];
    NSArray *maintenanceArguments = MaintenanceArguments(@"/Users/test/Theme With Spaces", @"dock-preference-change");
    BOOL maintenanceCommand = [maintenanceArguments isEqualToArray:@[@"/Users/test/Theme With Spaces/scripts/dock-repair.py",
                                                                   @"--reason", @"dock-preference-change"]];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@{@"kind": @"attachment", @"pid": @123}];
    BOOL maintenanceDedup = QueueMaintenanceOnce(queue) && !QueueMaintenanceOnce(queue) && queue.count == 2;
    [queue removeLastObject];
    BOOL maintenanceRequeue = QueueMaintenanceOnce(queue) && queue.count == 2;
    NSDictionary *first = @{@"device": @1, @"inode": @10, @"size": @1};
    NSDictionary *write = @{@"device": @1, @"inode": @10, @"size": @2};
    NSDictionary *replace = @{@"device": @1, @"inode": @11, @"size": @2};
    BOOL identity = SameFileIdentity(first, write) && !SameFileIdentity(first, replace) && !SameFileIdentity(first, nil);
    ThemeObserverSelfTest *probe = [[ThemeObserverSelfTest alloc] init];
    probe.queue = [NSMutableArray array];
    probe.maintenanceReasons = [NSMutableSet set];
    [probe scheduleMaintenance:@"first"];
    [probe scheduleMaintenance:@"second"];
    [probe scheduleMaintenance:@"first"];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.55]];
    BOOL debounce = probe.queue.count == 1 && probe.maintenanceReasons.count == 2 &&
                    probe.drainCalls == 1 && probe.maintenanceDebounce == nil;
    [probe scheduleMaintenance:@"third"];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.55]];
    BOOL queuedDebounce = probe.queue.count == 1 && probe.maintenanceReasons.count == 3 &&
                          probe.drainCalls == 2 && probe.maintenanceDebounce == nil;
    BOOL passed = filter && dedup && command && pidReuse && maintenanceCommand && maintenanceDedup && maintenanceRequeue && identity && debounce && queuedDebounce;
    NSDictionary *result = @{@"pass": @(passed), @"eventFilter": @(filter),
                             @"pidDeduplication": @(dedup), @"argumentConstruction": @(command),
                             @"pidReuseAfterTermination": @(pidReuse),
                             @"maintenanceArguments": @(maintenanceCommand),
                             @"pendingMaintenanceDeduplication": @(maintenanceDedup),
                             @"maintenanceRequeueAfterDrain": @(maintenanceRequeue),
                             @"atomicReplacementIdentity": @(identity),
                             @"oneShotDebounceCoalescing": @(debounce),
                             @"alreadyQueuedEventCoalescing": @(queuedDebounce),
                             @"monitorsStarted": @NO, @"applicationsStarted": @NO};
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return passed ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return SelfTest();
        if (argc != 3) {
            fprintf(stderr, "usage: codex-theme-observer <absolute theme root> <absolute Python executable>\n");
            return 2;
        }
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSString *python = [NSString stringWithUTF8String:argv[2]];
        if (!root.isAbsolutePath || !python.isAbsolutePath ||
            ![[NSFileManager defaultManager] isExecutableFileAtPath:python] ||
            ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"scripts/auto-attach.py"]] ||
            ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"scripts/dock-repair.py"]]) {
            fprintf(stderr, "codex-theme-observer: require absolute paths, executable Python, and both attachment/maintenance scripts\n");
            return 2;
        }
        ThemeObserver *observer = [[ThemeObserver alloc] init];
        observer.root = root.stringByStandardizingPath;
        observer.python = python.stringByStandardizingPath;
        NSError *error = nil;
        if (![observer start:&error]) {
            fprintf(stderr, "codex-theme-observer: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
