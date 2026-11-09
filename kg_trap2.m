#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <string.h>
#import <signal.h>
#import <ucontext.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <unistd.h>

// SIGTRAP 自我调试（支持 arm64 / x86_64）
static IMP g_imp = NULL;
static uint32_t g_orig = 0;
static uint32_t *g_target = NULL;
static int g_hits = 0;

static void dump_mem(const char *label, uint64_t p) {
    if (p < 0x1000 || p > 0x7fffffffffffULL) return;
    unsigned char buf[48] = {0};
    vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)p,
                                         48, (vm_address_t)buf, &out);
    if (kr != KERN_SUCCESS) return;
    NSMutableString *hex = [NSMutableString string];
    NSMutableString *asc = [NSMutableString string];
    for (int k = 0; k < 32; k++) {
        [hex appendFormat:@"%02x", buf[k]];
        unsigned char c = buf[k];
        [asc appendFormat:@"%c", (c >= 32 && c < 127) ? c : '.'];
    }
    NSLog(@"[KG]  *%s(0x%llx) -> %@ | %@", label,
          (unsigned long long)p, hex, asc);
}

static void trap_handler(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = (ucontext_t *)ctx;
#if defined(__x86_64__)
    uint64_t pc = uc->uc_mcontext->__ss.__rip;
    uint64_t a0 = uc->uc_mcontext->__ss.__rdi;
    uint64_t a1 = uc->uc_mcontext->__ss.__rsi;
    uint64_t a2 = uc->uc_mcontext->__ss.__rdx;
    uint64_t a3 = uc->uc_mcontext->__ss.__rcx;
    uint64_t a4 = uc->uc_mcontext->__ss.__r8;
    uint64_t a5 = uc->uc_mcontext->__ss.__r9;
#else
    uint64_t *xr = uc->uc_mcontext->__ss.__x;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    uint64_t a0 = xr[0], a1 = xr[1], a2 = xr[2];
    uint64_t a3 = xr[3], a4 = xr[4], a5 = xr[5];
#endif

    if (g_target && pc == (uint64_t)g_target && g_hits < 8) {
        g_hits++;
        NSLog(@"[KG] ==== HIT #%d pc=0x%llx ====", g_hits, (unsigned long long)pc);
        NSLog(@"[KG]  a0=0x%llx a1=0x%llx a2=0x%llx",
              (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2);
        NSLog(@"[KG]  a3=0x%llx a4=0x%llx a5=0x%llx",
              (unsigned long long)a3, (unsigned long long)a4, (unsigned long long)a5);
        dump_mem("a0", a0);
        dump_mem("a1", a1);
        dump_mem("a2", a2);
        dump_mem("a3", a3);

        *g_target = g_orig;
        __builtin___clear_cache((char *)g_target, (char *)g_target + 4);
#if defined(__x86_64__)
        uc->uc_mcontext->__ss.__rip = (uint64_t)g_target;
#else
        uc->uc_mcontext->__ss.__pc = (uint64_t)g_target;
#endif
        return;
    }
    signal(SIGTRAP, SIG_DFL);
    raise(SIGTRAP);
}

static int install_trap(void *addr, const char *tag) {
    if (!addr) return 0;
    uint32_t *p = (uint32_t *)addr;
    long pagesize = sysconf(_SC_PAGESIZE);
    void *page = (void *)((uintptr_t)p & ~(uintptr_t)(pagesize - 1));

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page,
                                  (vm_size_t)pagesize, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        int r = mprotect(page, pagesize, PROT_READ | PROT_WRITE | PROT_EXEC);
        if (r != 0) {
            NSLog(@"[KG] 页保护失败 kr=%d errno=%d (%s)", kr, errno, tag);
            return 0;
        }
    }
    g_target = p;
    g_orig = *p;
    NSLog(@"[KG] 目标 %s @ %p 原指令=0x%08x", tag, p, g_orig);
    *p = 0xD4200000u;   // brk #0 (arm64) / 在 x86_64 上会被解释成别的指令
#if defined(__x86_64__)
    *p = 0xCCCCCCCCu;   // int3 x4 —— 用 0xCC 触发 SIGTRAP
#endif
    __builtin___clear_cache((char *)p, (char *)p + 4);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = trap_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGTRAP, &sa, NULL);
    return 1;
}

static void run(void) {
    Class c = NSClassFromString(@"KGSerialNumberGenerator");
    if (!c) { NSLog(@"[KG] 类无"); exit(1); }
    Method m = class_getInstanceMethod(c, @selector(createSerial:));
    if (!m) { NSLog(@"[KG] 方法无"); exit(1); }
    g_imp = method_getImplementation(m);
    NSLog(@"[KG] createSerial: IMP = %p", (void *)g_imp);

    void *signCall = (void *)((uintptr_t)g_imp + 0x268);
    install_trap(signCall, "signCall(+0x268)");

    id obj = [[c alloc] init];
    NSTextField *nf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    NSTextField *sf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    NSPopUpButton *pm = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [pm addItemsWithTitles:@[@"Farrago"]];
    [obj setValue:nf forKey:@"nameField"];
    [obj setValue:sf forKey:@"serialField"];
    [obj setValue:pm forKey:@"popupMenu"];
    [pm selectItemAtIndex:0];
    @try { [obj performSelector:@selector(popupSelector:) withObject:pm]; } @catch (NSException *e) {}

    [nf setStringValue:@"TraceMe"];
    [sf setStringValue:@""];
    @try { [obj performSelector:@selector(createSerial:) withObject:nil]; }
    @catch (NSException *e) { NSLog(@"[KG] 异常 %@", e.reason); }
    NSLog(@"[KG] >>> %@", [sf stringValue]);
    NSLog(@"[KG] 命中 %d 次", g_hits);
}

__attribute__((constructor))
static void boot(void) {
    NSLog(@"[KG] trap2 loaded (%s)",
#if defined(__x86_64__)
          "x86_64"
#else
          "arm64"
#endif
          );
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { run(); } @catch (NSException *e) { NSLog(@"[KG] 顶层 %@", e.reason); }
        exit(0);
    });
}
