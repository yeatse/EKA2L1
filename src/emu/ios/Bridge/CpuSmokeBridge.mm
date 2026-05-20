// Stage-1 CPU smoke bridge implementation. See CpuSmokeBridge.h.
//
// The bridge wires a dyncom arm::core to a single host-backed code page,
// drives it through the bkpt-terminated A32 blob in CpuSmokeBlob.h, and
// compares the resulting register state against the snapshot the
// generator pinned at build time.

#import <Foundation/Foundation.h>
#import <os/log.h>
#include <cstdio>

#import "CpuSmokeBridge.h"
#import "CpuSmokeBlob.h"

#include <common/log.h>
#include <common/types.h>
#include <cpu/arm_factory.h>
#include <cpu/arm_interface.h>
#include <cpu/arm_utils.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

@implementation EKA2L1CpuSmokeResult
@end

namespace {

constexpr std::uint32_t kStackTop = 0x0002'0000u;  // arbitrary, not actually backed
constexpr std::uint32_t kLrSentinel = 0xCAFE'BABEu;
// USER32MODE (0x10) with both IRQ (I, bit 7) and FIQ (F, bit 6) disabled so
// dyncom's DISPATCH path doesn't bail on an "interrupt pending" check before
// executing a single instruction.
constexpr std::uint32_t kCpsrUserMode = 0x10u | 0x80u | 0x40u;
constexpr std::uint32_t kMaxInstructions = 64u;

arm_emulator_type to_arm_type(EKA2L1SmokeBackend backend) {
    switch (backend) {
        case EKA2L1SmokeBackendDynarmic:
            return arm_emulator_type::dynarmic;
        case EKA2L1SmokeBackendDyncom:
        default:
            return arm_emulator_type::dyncom;
    }
}

EKA2L1SmokeBackend from_arm_type(arm_emulator_type type) {
    switch (type) {
        case arm_emulator_type::dynarmic:
            return EKA2L1SmokeBackendDynarmic;
        case arm_emulator_type::dyncom:
        default:
            return EKA2L1SmokeBackendDyncom;
    }
}

struct PageBackedCore {
    std::vector<std::uint8_t> code_page;
    std::atomic<bool> stopped{false};
    std::uint32_t pc_at_stop = 0;
    std::uint32_t exception_data = 0;
    eka2l1::arm::exception_type exception_kind = eka2l1::arm::exception_type_unk;

    PageBackedCore() : code_page(eka2l1::ios::smoke::PAGE_SIZE, 0) {
        // Pre-fill the page with `b .` (0xEAFFFFFE) so dyncom's basic-block
        // translator, which keeps decoding past our bkpt terminator, hits a
        // self-branch (DIRECT_BRANCH) instead of a zero word that the
        // decoder treats as a hard failure and aborts on.
        constexpr std::uint32_t branch_self = 0xEAFFFFFEu;
        auto *words = reinterpret_cast<std::uint32_t *>(code_page.data());
        for (std::size_t i = 0; i < code_page.size() / sizeof(std::uint32_t); ++i) {
            words[i] = branch_self;
        }
        std::memcpy(code_page.data(),
                    eka2l1::ios::smoke::CODE_WORDS.data(),
                    eka2l1::ios::smoke::CODE_WORDS.size() * sizeof(std::uint32_t));
    }

    bool contains_vaddr(std::uint32_t vaddr) const {
        return vaddr >= eka2l1::ios::smoke::CODE_BASE_VADDR
            && vaddr < eka2l1::ios::smoke::CODE_BASE_VADDR + code_page.size();
    }

    std::uint8_t *host_for(std::uint32_t vaddr) {
        return code_page.data() + (vaddr - eka2l1::ios::smoke::CODE_BASE_VADDR);
    }
};

template <typename T>
bool read_typed(PageBackedCore &page, std::uint32_t vaddr, T *out) {
    if (!page.contains_vaddr(vaddr) || !page.contains_vaddr(vaddr + sizeof(T) - 1)) {
        return false;
    }
    std::memcpy(out, page.host_for(vaddr), sizeof(T));
    return true;
}

void install_callbacks(eka2l1::arm::core &core, PageBackedCore &page) {
    core.read_8bit = [&page](eka2l1::arm::address addr, std::uint8_t *out) {
        return read_typed(page, addr, out);
    };
    core.read_16bit = [&page](eka2l1::arm::address addr, std::uint16_t *out) {
        return read_typed(page, addr, out);
    };
    core.read_32bit = [&page](eka2l1::arm::address addr, std::uint32_t *out) {
        return read_typed(page, addr, out);
    };
    core.read_64bit = [&page](eka2l1::arm::address addr, std::uint64_t *out) {
        return read_typed(page, addr, out);
    };
    core.read_code = [&page](eka2l1::arm::address addr, std::uint32_t *out) {
        return read_typed(page, addr, out);
    };

    // The blob never writes to memory; treat all writes as failures so we
    // notice any deviation immediately.
    core.write_8bit = [](eka2l1::arm::address, std::uint8_t *) { return false; };
    core.write_16bit = [](eka2l1::arm::address, std::uint16_t *) { return false; };
    core.write_32bit = [](eka2l1::arm::address, std::uint32_t *) { return false; };
    core.write_64bit = [](eka2l1::arm::address, std::uint64_t *) { return false; };

    core.system_call_handler = [](std::uint32_t) {};

    core.exception_handler = [&page, &core](eka2l1::arm::exception_type kind, std::uint32_t data) -> bool {
        page.exception_kind = kind;
        page.exception_data = data;
        page.pc_at_stop = data;  // bkpt path passes Reg[15] as data
        page.stopped.store(true, std::memory_order_release);
        core.stop();
        return false;  // do not retry, just unwind
    };
}

}  // namespace

@implementation EKA2L1CpuSmokeBridge

+ (void)initialize {
    if (self == [EKA2L1CpuSmokeBridge class]) {
        // dyncom calls LOG_DEBUG from BKPT_INST, which dereferences the
        // common::log singleton; without setup_log() it crashes on the
        // first bkpt. Initialize once per process before any cpu call.
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // setup_log() creates an EKA2L1.log file in the current working
            // directory. On iOS the bundle is read-only, so chdir to the
            // sandbox Documents directory first; spdlog's basic_file_sink
            // would otherwise throw and abort the process.
            NSString *docs = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            if (docs) {
                chdir(docs.fileSystemRepresentation);
            }
            eka2l1::log::setup_log(nullptr);
        });
    }
}

+ (EKA2L1CpuSmokeResult *)runWithBackend:(EKA2L1SmokeBackend)backend {
    EKA2L1CpuSmokeResult *result = [[EKA2L1CpuSmokeResult alloc] init];
    result.requestedBackend = backend;

    const arm_emulator_type requested = to_arm_type(backend);
    const char *reason_cstr = nullptr;
    const arm_emulator_type resolved =
        eka2l1::arm::resolve_emulator_type(requested, &reason_cstr);
    result.resolvedBackend = from_arm_type(resolved);
    result.fallbackReason = reason_cstr ? @(reason_cstr) : nil;

    auto core = eka2l1::arm::create_core(nullptr, requested);
    if (!core) {
        result.pass = NO;
        result.diff = @"arm::create_core returned nullptr";
        return result;
    }

    PageBackedCore page;
    install_callbacks(*core, page);

    core->set_tlb_page(eka2l1::ios::smoke::CODE_BASE_VADDR,
                       page.code_page.data(),
                       prot_read_exec);

    for (std::size_t i = 0; i < 13; ++i) {
        core->set_reg(i, 0);
    }
    core->set_sp(kStackTop);
    core->set_lr(kLrSentinel);
    core->set_pc(eka2l1::ios::smoke::CODE_BASE_VADDR);
    core->set_cpsr(kCpsrUserMode);

    core->run(kMaxInstructions);

    result.instructionsExecuted = core->get_num_instruction_executed();

    NSMutableArray<NSNumber *> *regs = [NSMutableArray arrayWithCapacity:13];
    for (std::size_t i = 0; i < 13; ++i) {
        [regs addObject:@(core->get_reg(i))];
    }
    result.registers = regs;
    result.pc = core->get_pc();
    result.sp = core->get_sp();
    result.lr = core->get_lr();
    result.cpsr = core->get_cpsr();

    NSMutableString *diff = [NSMutableString string];
    BOOL ok = page.stopped.load(std::memory_order_acquire);
    if (!ok) {
        [diff appendString:@"exception_handler never fired (bkpt did not stop the core)\n"];
    }
    if (page.exception_kind != eka2l1::arm::exception_type_breakpoint) {
        [diff appendFormat:@"expected exception_type_breakpoint, got %d\n",
                            static_cast<int>(page.exception_kind)];
    }
    for (std::size_t i = 0; i < 13; ++i) {
        const std::uint32_t actual = [regs[i] unsignedIntValue];
        const std::uint32_t expected = eka2l1::ios::smoke::EXPECTED_R0_R12[i];
        if (actual != expected) {
            [diff appendFormat:@"r%zu: expected 0x%08X, got 0x%08X\n", i, expected, actual];
        }
    }

    result.pass = (diff.length == 0);
    result.diff = result.pass ? nil : [diff copy];

    // Stage-1 SmokeBridge prints a single line that scripts/build_ios.sh
    // greps for. Keep the prefix and PASS/FAIL token stable. Emit through
    // stderr (captured by simctl --console-pty), os_log (captured by
    // `simctl spawn log show`), and NSLog (belt-and-braces).
    const char *resolvedName = (resolved == arm_emulator_type::dyncom) ? "dyncom" : "dynarmic";
    char marker[256];
    if (result.pass) {
        std::snprintf(marker, sizeof(marker),
                      "EKA2L1_SMOKE: PASS backend=%s instrs=%u pc=0x%08X",
                      resolvedName, result.instructionsExecuted, result.pc);
    } else {
        std::snprintf(marker, sizeof(marker),
                      "EKA2L1_SMOKE: FAIL backend=%s", resolvedName);
    }
    std::fputs(marker, stderr);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    os_log(OS_LOG_DEFAULT, "%{public}s", marker);
    NSLog(@"%s", marker);

    return result;
}

@end
