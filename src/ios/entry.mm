// Dylib entry point.
//
// Injected into /usr/libexec/backboardd by ElleKit/TweakInject. Deliberately
// minimal: initialise logging, publish the build identity, start the command
// server. All command logic lives in ipc.mm / hid.mm / capture.mm and the
// portable core.
#include <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ios.hpp"

#ifndef AUTIVA_BUILD
#define AUTIVA_BUILD "dev"
#endif
#define AUTIVA_VERSION "12.0.0"

namespace autiva {
namespace {

long log_bytes() {
    struct stat st {};
    if (stat(kLogPath, &st) != 0) return 0;
    return static_cast<long>(st.st_size);
}

}  // namespace

std::string version_json() {
    std::string out = "{\"v\":\"" AUTIVA_VERSION "\",\"build\":\"" AUTIVA_BUILD "\"";
    out += ",\"pid\":" + std::to_string(getpid());
    out += ",\"screen\":[" + std::to_string(kScreenW) + "," + std::to_string(kScreenH) + "]";
    out += ",\"log_bytes\":";
    out += std::to_string(log_bytes());
    out += ",\"ipc\":\"mailbox\"";
    out += ",\"caps\":{";
    // `socket` is reported false because this process cannot create one:
    // measured EPERM on bind inside backboardd's sandbox (2026-11-11).
    out += "\"socket\":false,\"mailbox\":true,\"legacy_file\":true";
    out += ",\"ids\":true,\"delivered\":true";
    out += ",\"clipboard\":false,\"clipboard_read\":true,\"screenshot\":true";
    // Capabilities that arrive in later versions must be reported honestly so
    // the host never calls an action that does not exist yet.
    out += ",\"plan\":true,\"record\":";
    out += monitor_available() ? "true" : "false";
    out += ",\"record_takes\":true,\"monitor\":";
    out += monitor_available() ? "true" : "false";
    out += "";
    out += ",\"idletimer\":";
    out += hid_idle_timer_available() ? "true" : "false";
    out += ",\"radii\":true,\"sampled_waveform\":true";
    out += "}}";
    return out;
}

}  // namespace autiva

__attribute__((constructor)) static void autiva_init() {
    using namespace autiva;
    log_init();

    NSString* marker = [NSString stringWithFormat:@"%s %s pid=%d", AUTIVA_VERSION,
                                                  AUTIVA_BUILD, getpid()];
    [marker writeToFile:[NSString stringWithUTF8String:kLoadedMarker]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];

    log_line(std::string("=== Autiva/SBTouch v") + AUTIVA_VERSION + " (build " +
             AUTIVA_BUILD + ") loaded into backboardd pid=" + std::to_string(getpid()) +
             " ===");

    // backboardd is still settling for the first second or two after a respring;
    // the socket is safe to open immediately, the file poller waits.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500ull * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                       autiva::ipc_start();
                   });
}
