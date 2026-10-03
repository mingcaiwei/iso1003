//
//  EthernetLauncher - 以太网接入时拉起指定 App 的 TrollStore 守护进程
//
//  功能：
//    常驻后台守护。当检测到「以太网」接入（从未连接 -> 已连接）时，
//    把目标 App 拉起一次（不在已连接状态下反复拉起）。
//
//  目标 App 的 Bundle ID 在下方 TVTargetBundleID 宏中固定写死。
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>

// ==========================================================================
//  配置区：要拉起的 App 的 Bundle ID（用户提供）
// ==========================================================================
#define TVTargetBundleID  @"ceshi0607.com.nxs"

// 首次发现以太网已连通时，是否也触发一次（推荐 YES，应对守护进程晚于网卡就绪启动的情况）
#define TVTriggerOnInitialConnect  1

// 两次拉起之间的最小间隔（秒），避免网络抖动导致重复拉起
#define TVLaunchCooldownSeconds    20

// ==========================================================================
//  日志
// ==========================================================================
static void TVLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    // 写入文件日志，方便排查（TrollStore 免沙盒，可写 /var/mobile 等）
    NSString *logPath = @"/var/mobile/Library/Logs/EthernetLauncher.log";
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[logPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:NULL];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    }

    fputs(line.UTF8String, stderr);
}

// ==========================================================================
//  以太网状态检测
// ==========================================================================
// 记录「当前主接口是否是以太网且已连通」，回调里用来判断变化
static BOOL gLastEthernetConnected = NO;
static int  gLastReachabilityFlags  = 0;

// 判断指定 BSD 接口名是否是以太网（WiFi 为 en0/en1 也可能是以太网扩展坞，
// 因此这里通过 SystemConfiguration 的接口类型而不是硬编码 en 前缀来判断）
static BOOL TVInterfaceIsEthernet(NSString *bsdName) {
    if (bsdName.length == 0) return NO;

    SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("EthernetLauncher"), NULL);
    if (!prefs) return NO;

    BOOL isEthernet = NO;

    // 遍历所有网络服务，找到匹配该 BSD 接口的服务，读取其 Interface Type
    CFArrayRef services = SCNetworkServiceCopyAll(prefs);
    if (services) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            SCNetworkServiceRef service = (SCNetworkServiceRef)CFArrayGetValueAtIndex(services, i);
            SCNetworkInterfaceRef iface = SCNetworkServiceGetInterface(service);
            if (!iface) continue;

            CFStringRef ifBSDN = SCNetworkInterfaceGetBSDName(iface);
            if (!ifBSDN) continue;
            if (![(__bridge NSString *)ifBSDN isEqualToString:bsdName]) continue;

            CFStringRef type = SCNetworkInterfaceGetInterfaceType(iface);
            if (type) {
                if (CFStringCompare(type, kSCNetworkInterfaceTypeEthernet, 0) == kCFCompareEqualTo) {
                    isEthernet = YES;
                } else {
                    // 明确排除 WiFi
                    isEthernet = NO;
                }
            }
            break;
        }
        CFRelease(services);
    }

    CFRelease(prefs);
    return isEthernet;
}

// 获取当前主接口的 BSD 名（如 en0 / en5）
static NSString *TVPrimaryInterfaceBSDName(void) {
    NSString *result = nil;
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("EthernetLauncher"), NULL, NULL);
    if (!store) return nil;

    CFStringRef globalKey = SCDynamicStoreKeyCreateNetworkGlobalEntity(
        NULL, kSCDynamicStoreDomainState, kSCEntNetIPv4);
    CFDictionaryRef global = SCDynamicStoreCopyValue(store, globalKey);
    if (global) {
        CFStringRef primary = CFDictionaryGetValue(global, kSCDynamicStorePropNetPrimaryInterface);
        if (primary) result = [NSString stringWithString:(__bridge NSString *)primary];
        CFRelease(global);
    }
    if (globalKey) CFRelease(globalKey);
    CFRelease(store);
    return result;
}

// 综合判断：是否「以太网已连通」
static BOOL TVIsEthernetConnected(void) {
    // 1. 必须先有主接口
    NSString *bsd = TVPrimaryInterfaceBSDName();
    if (bsd.length == 0) return NO;

    // 2. 该接口必须是以太网类型
    if (!TVInterfaceIsEthernet(bsd)) return NO;

    // 3. 用可达性再确认一次连通
    SCNetworkReachabilityRef reach = SCNetworkReachabilityCreateWithName(
        NULL, "1.1.1.1");
    if (!reach) return NO;
    SCNetworkReachabilityFlags flags = 0;
    BOOL ok = SCNetworkReachabilityGetFlags(reach, &flags);
    CFRelease(reach);
    if (!ok) return NO;

    BOOL reachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL needsConn = (flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0;
    return reachable && !needsConn;
}

// ==========================================================================
//  拉起目标 App
// ==========================================================================
static BOOL TVLaunchTargetApp(void) {
    static NSDate *lastLaunch = nil;
    NSDate *now = [NSDate date];
    if (lastLaunch && [now timeIntervalSinceDate:lastLaunch] < TVLaunchCooldownSeconds) {
        TVLog(@"launch skipped (cooldown)");
        return NO;
    }

    void *handle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    if (!handle) {
        TVLog(@"dlopen FrontBoardServices failed: %s", dlerror());
        return NO;
    }

    // SBSLaunchApplicationWithIdentifier(CFStringRef bundleID, Boolean suspended)
    typedef int (*SBSLaunchFn)(CFStringRef, Boolean);
    SBSLaunchFn launch = (SBSLaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifier");
    if (!launch) {
        TVLog(@"dlsym SBSLaunchApplicationWithIdentifier failed");
        dlclose(handle);
        return NO;
    }

    int rc = launch((__bridge CFStringRef)TVTargetBundleID, false);
    dlclose(handle);

    lastLaunch = now;
    TVLog(@"launch %@ -> rc=%d", TVTargetBundleID, rc);
    return rc == 0;
}

// ==========================================================================
//  网络可达性回调
// ==========================================================================
static void TVReachabilityCallback(SCNetworkReachabilityRef target,
                                   SCNetworkReachabilityFlags flags,
                                   void *info) {
    (void)target; (void)info;
    gLastReachabilityFlags = (int)flags;

    BOOL connected = TVIsEthernetConnected();
    TVLog(@"reachability changed: ethernetConnected=%d (was=%d) flags=0x%x",
          connected, gLastEthernetConnected, flags);

    if (connected && !gLastEthernetConnected) {
        TVLog(@"ethernet connected, triggering app launch");
        TVLaunchTargetApp();
    }
    gLastEthernetConnected = connected;
}

// ==========================================================================
//  main
// ==========================================================================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 守护进程不该被终端信号干掉
        signal(SIGTERM, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);
        signal(SIGHUP,  SIG_IGN);

        setvbuf(stderr, NULL, _IONBF, 0);

        TVLog(@"==================================================");
        TVLog(@"EthernetLauncher started (pid=%d)", getpid());
        TVLog(@"target bundle id = %@", TVTargetBundleID);

        // 初始状态
        gLastEthernetConnected = TVIsEthernetConnected();
        TVLog(@"initial state: ethernetConnected=%d", gLastEthernetConnected);

#if TVTriggerOnInitialConnect
        if (gLastEthernetConnected) {
            TVLog(@"already connected at startup, triggering initial launch");
            TVLaunchTargetApp();
        }
#endif

        // 建立可达性监控（对 0.0.0.0 建，任何网络变化都会回调）
        struct sockaddr_in zeroAddr;
        memset(&zeroAddr, 0, sizeof(zeroAddr));
        zeroAddr.sin_len    = sizeof(zeroAddr);
        zeroAddr.sin_family = AF_INET;
        zeroAddr.sin_addr.s_addr = htonl(INADDR_ANY);

        SCNetworkReachabilityRef reach = SCNetworkReachabilityCreateWithAddress(
            NULL, (const struct sockaddr *)&zeroAddr);
        if (!reach) {
            TVLog(@"SCNetworkReachabilityCreateWithAddress failed");
            return 1;
        }

        SCNetworkReachabilityContext ctx = { 0, NULL, NULL, NULL, NULL };
        if (!SCNetworkReachabilitySetCallback(reach, TVReachabilityCallback, &ctx)) {
            TVLog(@"SCNetworkReachabilitySetCallback failed");
        }

        dispatch_queue_t queue = dispatch_queue_create("com.ceshi.ethlauncher.reach", NULL);
        if (!SCNetworkReachabilitySetDispatchQueue(reach, queue)) {
            TVLog(@"SCNetworkReachabilitySetDispatchQueue failed");
        }

        TVLog(@"reachability monitor started");

        // 常驻
        [[NSRunLoop currentRunLoop] run];

        CFRelease(reach);
    }
    return 0;
}
