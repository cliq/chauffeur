// A separate sandbox app owns only synthetic test data.
#import <Foundation/Foundation.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/chauffeur-tcc-sentinel.txt"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (argc > 1 && !strcmp(argv[1], "cleanup")) {
            return [files removeItemAtPath:path error:NULL] ? 0 : 1;
        }
        NSError *error = nil;
        [files createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:&error];
        BOOL ok = [@"Synthetic Chauffeur AppData fixture.\n" writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:&error];
        if (!ok) NSLog(@"Fixture creation failed: %@", error);
        return ok ? 0 : 1;
    }
}
