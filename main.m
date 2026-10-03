//
//  EthernetLauncher - 以太网接入时拉起指定 App 的 TrollStore 守护进程
//
//  功能：
//    常驻后台守护。当检测到「以太网」接入（从未连接 -> 已连接）时，
//    把目标 App 拉起一次（不在已连接状态下反复拉起）。
//
//  说明：
//    iOS SDK 将 SCPreferences* / SCDynamicStore* 标记为 iOS 不可用，
//    因此这里使用纯 POSIX getifaddrs() 枚举网卡来判断以太网状态。
//
//  目标 App 的 Bundle ID 在下方 TVTargetBundleID 宏中固定写死。
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <signal.h>
#import <string.h>
#import <sys/ioctl.h>
#import <unistd.h>

// ==========================================================================
//  配置区：要拉起的 App 的 Bundle ID（用户提供）
// ==========================================================================
#define TVTargetBundleID  @"ceshi0607.com.nxs"

// 首次发现以太网已连通时，是否也触发一次（推荐 1，应对守护进程晚于网卡就绪启动的情况）
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
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:[NSDate date]], msg];

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
//  网卡工具
// ==========================================================================
// 是否是需要忽略的虚拟/特殊接口
static BOOL TVIsIgnoredInterface(const char *name) {
    static const char *prefixes[] = {
        "lo", "pdp_ip", "awdl", "llw", "utun", "ipsec", "anpi",
        "bridge", "pktap", "gif", "stf", "XHC", "ap", "nan", "vmenet", NULL
    };
    for (int i = 0; prefixes[i]; i++) {
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) return YES;
    }
    return NO;
}

// 通过 ioctl 读取接口的介质类型（无 WiFi 的 en* 视为以太网）
// 返回 YES 表示该接口当前处于「已激活」(running)
static BOOL TVInterfaceIsActive(const char *name) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return NO;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);

    BOOL active = NO;
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) == 0) {
        if ((ifr.ifr_flags & IFF_UP) && (ifr.ifr_flags & IFF_RUNNING)) {
            active = YES;
        }
    }
    close(sock);
    return active;
}

// 返回第一个「已连通的以太网接口名」，没有则返回 nil
// 判据：接口名以 en 开头、非忽略前缀、接口 UP+RUNNING、且已分配到 IPv4 地址。
// 说明：WiFi 在 iOS 上同样是 en0，而 USB 网卡/扩展坞通常是 en5 及以后。
//       如果需要严格区分，可在此处排除 en0；当前实现按「en* 上有 IPv4 且 RUNNING」判定。
static NSString *TVConnectedEthernetInterface(void) {
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0 || ifaddr == NULL) return nil;

    NSString *found = nil;

    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr) continue;
        if (ifa->ifa_addr->sa_family != AF_INET) continue;
        // 只用 IPv4 主地址（跳过 127.x）
        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        if (sin->sin_addr.s_addr == htonl(INADDR_LOOPBACK)) continue;

        const char *name = ifa->ifa_name;
        if (TVIsIgnoredInterface(name)) continue;
        if (strncmp(name, "en", 2) != 0) continue;   // 仅物理网卡
        if (!TVInterfaceIsActive(name)) continue;

        found = [NSString stringWithUTF8String:name];
        break;
    }

    freeifaddrs(ifaddr);
    return found;
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
//  网络可达性回调（任何网络变化都会触发，再自行判断以太网状态）
// ==========================================================================
static BOOL gLastEthernetConnected = NO;

static void TVReachabilityCallback(SCNetworkReachabilityRef target,
                                   SCNetworkReachabilityFlags flags,
                                   void *info) {
    (void)target; (void)info;

    NSString *ifName = TVConnectedEthernetInterface();
    BOOL connected = (ifName != nil);

    TVLog(@"reachability changed: ethernetConnected=%d (was=%d) iface=%@ flags=0x%x",
          connected, gLastEthernetConnected, ifName ?: @"-", flags);

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

        gLastEthernetConnected = (TVConnectedEthernetInterface() != nil);
        TVLog(@"initial state: ethernetConnected=%d iface=%@",
              gLastEthernetConnected,
              TVConnectedEthernetInterface() ?: @"-");

#if TVTriggerOnInitialConnect
        if (gLastEthernetConnected) {
            TVLog(@"already connected at startup, triggering initial launch");
            TVLaunchTargetApp();
        }
#endif

        // 对 0.0.0.0 建立可达性监控：任何网络变化都会回调
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

        // 兜底轮询：可达性回调在部分场景不触发，每 5 秒自查一次
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC),
            5ull * NSEC_PER_SEC, 1ull * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            NSString *ifName = TVConnectedEthernetInterface();
            BOOL connected = (ifName != nil);
            if (connected != gLastEthernetConnected) {
                TVLog(@"poll state change: ethernetConnected=%d (was=%d) iface=%@",
                      connected, gLastEthernetConnected, ifName ?: @"-");
                if (connected) {
                    TVLog(@"ethernet connected (poll), triggering app launch");
                    TVLaunchTargetApp();
                }
                gLastEthernetConnected = connected;
            }
        });
        dispatch_resume(timer);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
