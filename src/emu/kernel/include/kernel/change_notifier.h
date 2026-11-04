#pragma once

#include <kernel/kernel_obj.h>
#include <utils/reqsts.h>

#include <mem/mem.h>

#include <memory>

namespace eka2l1::kernel {
    class thread;

    class change_notifier : public eka2l1::kernel::kernel_obj {
        epoc::notify_info req_info_;
        // Symbian initially reports all change classes except LowMemory; this is
        // an initial state notification, not evidence of an allocation failure.
        std::uint32_t changes_ = 0x17F;
        std::uint64_t requester_uid_ = 0;

        void complete(std::int32_t result);

    public:
        explicit change_notifier(kernel_system *kern);

        bool logon(eka2l1::ptr<epoc::request_status> request_sts);
        bool logon_cancel();

        void notify_change_requester(std::uint32_t changes);

        int destroy() override;

        void do_state(common::chunkyseri &seri) override;
    };
}
