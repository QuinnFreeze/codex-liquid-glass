#import <Foundation/Foundation.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *root = [bundle objectForInfoDictionaryKey:@"ThemeRoot"];
        NSString *python = [bundle objectForInfoDictionaryKey:@"PythonBinary"];
        if (root.length == 0 || python.length == 0) return 2;
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *logPath = [state stringByAppendingPathComponent:@"launcher.log"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath])
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [log seekToEndOfFile];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:python];
        NSMutableArray *args = [NSMutableArray arrayWithObject:[root stringByAppendingPathComponent:@"scripts/auto-launch.py"]];
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String:argv[i]];
            if (![argument hasPrefix:@"-psn_"]) [args addObject:argument];
        }
        task.arguments = args;
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        task.standardOutput = log;
        task.standardError = log;
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) return 1;
        [task waitUntilExit];
        return task.terminationStatus;
    }
}
