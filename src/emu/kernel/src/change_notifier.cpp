/*
 * Copyright (c) 2018 EKA2L1 Team.
 * 
 * This file is part of EKA2L1 project
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include <kernel/kernel.h>
#include <mem/mem.h>
#include <mem/ptr.h>

#include <kernel/change_notifier.h>

#include <common/chunkyseri.h>
#include <common/cvt.h>
#include <common/random.h>

#include <utils/err.h>

namespace eka2l1 {
    namespace kernel {
        change_notifier::change_notifier(kernel_system *kern)
            : eka2l1::kernel::kernel_obj(kern, "changenotifier" + common::to_string(eka2l1::random()),
                nullptr, kernel::access_type::local_access) {
            obj_type = object_type::change_notifier;
            req_info_.requester = nullptr;
            req_info_.is_eka1 = kern->is_eka1();
        }

        bool change_notifier::logon(eka2l1::ptr<epoc::request_status> request_sts) {
            // If this is already logon
            if (req_info_.sts) {
                return false;
            }

            req_info_.requester = kern->crr_thread();
            requester_uid_ = req_info_.requester->unique_id();
            req_info_.sts = request_sts;

            // NOTE: EKA1's change notifier does not change status to pending in euser.dll
            // So we need to do extra check here. So far this seems like the only instance in the library
            // This should fix stray signal
            req_info_.pending();

            if (changes_)
                complete(static_cast<std::int32_t>(changes_));

            return true;
        }

        bool change_notifier::logon_cancel() {
            if (req_info_.empty() || req_info_.requester != kern->crr_thread()
                || requester_uid_ != kern->crr_thread()->unique_id()) {
                return false;
            }

            complete(epoc::error_cancel);
            return true;
        }

        void change_notifier::complete(std::int32_t result) {
            if (req_info_.empty())
                return;
            // Clear ownership before signalling. The completion queues a guest
            // request; it never calls guest CActive::RunL on the kernel stack.
            epoc::notify_info pending = req_info_;
            const std::uint64_t requester_uid = requester_uid_;
            req_info_.sts = 0;
            req_info_.requester = nullptr;
            requester_uid_ = 0;
            changes_ = 0;
            if (!kern->is_wiping() && kern->is_thread_alive(pending.requester)
                && pending.requester->unique_id() == requester_uid
                && pending.requester->get_exit_type() == entity_exit_type::pending)
                pending.complete(result);
        }

        void change_notifier::notify_change_requester(std::uint32_t changes) {
            changes_ |= changes;
            if (!req_info_.empty())
                complete(static_cast<std::int32_t>(changes_));
        }

        int change_notifier::destroy() {
            // Closing a notifier cancels its pending request while the owner is
            // alive. Kernel teardown or an exited requester must not be signalled.
            complete(epoc::error_general);
            return kernel_obj::destroy();
        }

        void change_notifier::do_state(common::chunkyseri &seri) {
            seri.absorb(changes_);
            seri.absorb(requester_uid_);
            bool pending = !req_info_.empty();
            seri.absorb(pending);
            if (pending)
                req_info_.do_state(seri);
        }
    }
}
