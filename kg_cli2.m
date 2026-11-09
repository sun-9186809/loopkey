#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// kg_cli2 — 支持 22 个产品（按 tag）
// 环境变量: KG_NAME, KG_TAG(0-21), KG_OUT
static void run(void) {
    const char *nm = getenv("KG_NAME");
    const char *tg = getenv("KG_TAG");
    const char *op = getenv("KG_OUT");
    NSString *name = nm ? [NSString stringWithUTF8String:nm] : @"Test";
    int tag = tg ? atoi(tg) : 0;
    NSString *outFile = op ? [NSString stringWithUTF8String:op] : @"/tmp/kg_r.txt";

    Class c = NSClassFromString(@"KGSerialNumberGenerator");
    if (!c) { NSLog(@"[KG] 类无"); exit(1); }
    id obj = [[c alloc] init];
    NSTextField *nf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    NSTextField *sf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    NSPopUpButton *pm = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 400, 24)];
    for (int i = 0; i < 22; i++) {
        [pm addItemWithTitle:[NSString stringWithFormat:@"P%d", i]];
        [[pm lastItem] setTag:i];
    }
    [obj setValue:nf forKey:@"nameField"];
    [obj setValue:sf forKey:@"serialField"];
    [obj setValue:pm forKey:@"popupMenu"];

    if (tag < 0 || tag > 21) tag = 0;
    [pm selectItemAtIndex:tag];
    @try { [obj performSelector:@selector(popupSelector:) withObject:pm]; } @catch (NSException *e) {}

    [nf setStringValue:name];
    [sf setStringValue:@""];
    @try { [obj performSelector:@selector(createSerial:) withObject:nil]; }
    @catch (NSException *e) { NSLog(@"[KG] 异常 %@", e.reason); }

    NSString *s = [sf stringValue] ?: @"";
    NSString *line = [NSString stringWithFormat:@"%d|%@|%@\n", tag, name, s];
    [line writeToFile:outFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[KG] tag=%d %@ => %@", tag, name, s);
}

__attribute__((constructor))
static void boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { run(); } @catch (NSException *e) { NSLog(@"[KG] 顶层 %@", e.reason); }
        exit(0);
    });
}
