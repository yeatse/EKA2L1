/*
 * Copyright (c) 2019 EKA2L1 Team
 * 
 * This file is part of EKA2L1 project
 * (see bentokun.github.com/EKA2L1).
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

#include <services/fs/fs.h>
#include <services/fs/std.h>

#include <kernel/kernel.h>
#include <system/epoc.h>
#include <vfs/vfs.h>

#include <common/algorithm.h>
#include <common/cvt.h>
#include <common/log.h>
#include <common/path.h>
#include <common/random.h>
#include <common/virtualmem.h>
#include <kernel/chunk.h>
#include <kernel/thread.h>
#include <mem/mem.h>
#include <mem/control.h>
#include <mem/page.h>

#include <array>
#include <limits>
#include <utils/err.h>

#include <services/fs/sec.h>
#include <services/fs/op.h>

namespace eka2l1 {
    // Whether the directory is exactly the calling process's own private directory,
    // <drive>:\private\<sid>\.
    static bool is_process_own_private_dir(kernel::process *pr, const std::u16string &dir) {
        if (!pr) {
            return false;
        }

        const std::u16string root = eka2l1::root_name(dir, true);
        if (root.empty()) {
            return false;
        }

        const std::uint32_t uid = std::get<2>(pr->get_uid_type());
        const std::u16string own = root + u"\\private\\"
            + common::utf8_to_ucs2(common::uppercase_string(common::to_string(uid, std::hex))) + u"\\";

        std::u16string normalized = eka2l1::transform_separators<char16_t>(dir, true, eka2l1::get_separator_16);
        if (normalized.empty() || !eka2l1::is_separator(normalized.back())) {
            normalized += u'\\';
        }

        return common::compare_ignore_case(normalized, own) == 0;
    }

    // The sharing state is keyed by path, so the key has to be one single form of it:
    // a file opened as "c:/dir/f" and again as "c:\dir\f" is the same file.
    static std::u16string canonical_file_attrib_path(std::u16string path) {
        return eka2l1::transform_separators<char16_t>(
            std::move(path), true, eka2l1::get_separator_16);
    }

    bool file_attrib::claim_exclusive(const kernel::uid pr_uid) {
        if (owner == pr_uid) {
            flags |= static_cast<std::uint32_t>(fs_file_attrib_flag::exclusive);
            return true;
        }

        return false;
    }

    void file_attrib::increment_use(const kernel::uid pr_uid) {
        if (use_count == 0) {
            owner = pr_uid;
        }

        if (owner == pr_uid) {
            use_count++;
        }
    }

    void file_attrib::decrement_use(const kernel::uid pr_uid) {
        if (use_count == 0) {
            return;
        }

        if (pr_uid == owner) {
            use_count--;
        }

        if (use_count == 0) {
            // Clear all flags
            flags = 0;
            owner = 0;

            return;
        }
    }

    fs_node::~fs_node() {
        if (temporary) {
            io_system *io = serv->get_system()->get_io_system();

            if (vfs_node->type == io_component_type::file) { 
                file *vfs_file = reinterpret_cast<file *>(vfs_node.get());
                serv->temporary_file_cleanset_.emplace(common::lowercase_ucs2_string(vfs_file->file_name()));
            }
        }
    }

    void fs_node::deref() {
        if (vfs_node->type == io_component_type::file) {        
            file *vfs_file = reinterpret_cast<file *>(vfs_node.get());
            const std::u16string filename = canonical_file_attrib_path(vfs_file->file_name());

            auto ite = serv->attribs.find(filename);
            if (ite != serv->attribs.end()) {
                ite->second.decrement_use(process);
                if (ite->second.use_count == 0) {
                    serv->attribs.erase(ite);
                }
            }
        }

        epoc::ref_count_object::deref();
    }

    file *fs_server::get_file(const kernel::uid session_uid, const std::uint32_t handle) {
        auto ss = session<fs_server_client>(session_uid);

        if (!ss) {
            return nullptr;
        }

        return reinterpret_cast<eka2l1::file *>(ss->get_file_node(static_cast<int>(handle))->vfs_node.get());
    }

    symfile fs_server::get_temp_file(const std::u16string &base_dir) {
        std::u16string full_path = base_dir;
        io_system *io = sys->get_io_system();

        do {
            std::u16string temp_name{ u"temp" };
            temp_name += common::utf8_to_ucs2(common::to_string(eka2l1::random_range(0, 0xFFFFFFFE), std::hex));

            full_path = eka2l1::add_path(base_dir, temp_name);

            if (!io->exist(full_path)) {
                break;
            }
        } while (true);

        return io->open_file(full_path, WRITE_MODE | BIN_MODE);
    }

    void fs_server_client::file_modified(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *the_file = reinterpret_cast<file *>(node->vfs_node.get());
        epoc::time last_modified{ the_file->last_modify_since_0ad() };

        ctx->write_data_to_descriptor_argument<epoc::time>(0, last_modified);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_set_modified(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_size(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        // On Symbian^3 onwards, 64-bit file were supported, 64-bit integer for filesize used by default
        if (ctx->sys->get_kernel_system()->get_epoc_version() >= epocver::epoc95) {
            std::uint64_t fsize_u = reinterpret_cast<file *>(node->vfs_node.get())->size();
            ctx->write_data_to_descriptor_argument<uint64_t>(0, fsize_u);
        } else {
            std::uint32_t fsize_u = static_cast<std::uint32_t>(reinterpret_cast<file *>(node->vfs_node.get())->size());
            ctx->write_data_to_descriptor_argument<uint32_t>(0, fsize_u);
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_set_size(service::ipc_context *ctx) {
        std::optional<int> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        if (!(node->open_mode & WRITE_MODE) && !(node->open_mode & APPEND_MODE)) {
            // Can't set file size if the file is not open for write
            ctx->complete(epoc::error_permission_denied);
            return;
        }

        std::uint64_t size = 0;

        // UINT64 is passed in a descriptor
        if (ctx->msg->function & 0x10000) {
            std::optional<std::uint64_t> size_opt = ctx->get_argument_data_from_descriptor<std::uint64_t>(0);
            if (!size_opt.value()) {
                ctx->complete(epoc::error_argument);
            } else {
                size = size_opt.value();
            }
        } else {
            size = static_cast<std::uint64_t>(ctx->get_argument_value<std::int32_t>(0).value());
        }

        file *f = reinterpret_cast<file *>(node->vfs_node.get());
        std::size_t fsize = f->size();

        if (size == fsize) {
            ctx->complete(epoc::error_none);
            return;
        }

        // This is trying to prevent from data corruption that will affect the host
        if (size >= common::GB(1)) {
            LOG_ERROR(SERVICE_EFSRV, "File trying to resize to 1GB, operation not permitted");
            ctx->complete(epoc::error_too_big);

            return;
        }

        const std::uint64_t prev_pos = f->tell();

        bool res = f->resize(size);

        if (!res) {
            ctx->complete(epoc::error_general);
            return;
        }

        // If the file is truncated, move the file pointer to the maximum new size
        if (prev_pos > size) {
            f->seek(size, file_seek_mode::beg);
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_name(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *f = reinterpret_cast<file *>(node->vfs_node.get());

        ctx->write_arg(0, eka2l1::filename(f->file_name(), true));
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_full_name(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *f = reinterpret_cast<file *>(node->vfs_node.get());

        ctx->write_arg(0, f->file_name());
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_seek(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *vfs_file = reinterpret_cast<file *>(node->vfs_node.get());

        std::optional<std::int32_t> seek_mode = ctx->get_argument_value<std::int32_t>(1);
        std::optional<std::int64_t> seek_off = std::nullopt;

        if (ctx->msg->function & epoc::fs::ipc_arg_slot0_des) {
            seek_off = ctx->get_argument_data_from_descriptor<std::int64_t>(0);
        } else {
            seek_off = *ctx->get_argument_value<std::int32_t>(0);
        }

        if (!seek_mode || !seek_off) {
            ctx->complete(epoc::error_argument);
            return;
        }

        file_seek_mode vfs_seek_mode;

        switch (*seek_mode) {
        case 0: // ESeekAddress. Handle this as a normal seek start
            vfs_seek_mode = file_seek_mode::address;
            break;

        default:
            vfs_seek_mode = static_cast<file_seek_mode>(*seek_mode - 1);
            break;
        }

        // This should also support negative
        std::uint64_t seek_res = vfs_file->seek(*seek_off, vfs_seek_mode);

        if (seek_res == 0xFFFFFFFFFFFFFFFF) {
            ctx->complete(epoc::error_argument);
            return;
        }

        // Slot order: (0) seek offset, (1) seek mode, (2) new pos

        if ((int)ctx->sys->get_symbian_version_use() >= (int)epocver::epoc95) {
            ctx->write_data_to_descriptor_argument(2, seek_res);
        } else {
            int seek_result_i = static_cast<std::int32_t>(seek_res);
            ctx->write_data_to_descriptor_argument(2, seek_result_i);
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_flush(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *vfs_file = reinterpret_cast<file *>(node->vfs_node.get());

        // On Symbian, read-only file is fine with flushing. The VFS is changed to reflect this behaviour.
        if (!vfs_file->flush()) {
            LOG_ERROR(SERVICE_EFSRV, "Fail flushing file with path {}", common::ucs2_to_utf8(vfs_file->file_name()));

            ctx->complete(epoc::error_general);
            return;
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_rename(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *vfs_file = reinterpret_cast<file *>(node->vfs_node.get());
        const std::u16string old_path = vfs_file->file_name();
        auto new_path = ctx->get_argument_value<std::u16string>(0);

        if (!new_path) {
            ctx->complete(epoc::error_argument);
            return;
        }

        auto new_path_abs = get_full_symbian_path(ss_path, new_path.value());
        if (!check_path_capabilities_pass(new_path_abs, ctx->msg->own_thr->owning_process(), epoc::fs::private_comp_access_policy, epoc::fs::sys_resource_modify_access_policy, epoc::fs::sys_resource_modify_access_policy)) {
            ctx->complete(epoc::error_permission_denied);
            return;
        }

        bool res = ctx->sys->get_io_system()->rename(old_path, new_path_abs);

        if (!res) {
            ctx->complete(epoc::error_general);
            return;
        }

        // Save state of file and reopening it
        size_t last_pos = vfs_file->tell();
        int last_mode = vfs_file->file_mode();

        vfs_file->close();

        symfile new_vfs_file = ctx->sys->get_io_system()->open_file(new_path_abs, last_mode);

        if (!new_vfs_file) {
            // Renamed on disk, but the new path would not open. Say so, rather than
            // leaving the subsession holding a null file it dereferences next.
            LOG_ERROR(SERVICE_EFSRV, "Can't reopen {} after rename", common::ucs2_to_utf8(new_path_abs));
            ctx->complete(epoc::error_general);
            return;
        }

        new_vfs_file->seek(last_pos, file_seek_mode::beg);

        node->vfs_node = std::move(new_vfs_file);

        auto &attribs = server<fs_server>()->attribs;
        auto attrib_node = attribs.extract(canonical_file_attrib_path(old_path));
        if (!attrib_node.empty()) {
            attrib_node.key() = canonical_file_attrib_path(new_path_abs);
            auto insert_result = attribs.insert(std::move(attrib_node));
            if (!insert_result.inserted) {
                LOG_ERROR(SERVICE_EFSRV,
                    "File sharing state already exists after renaming {} to {}",
                    common::ucs2_to_utf8(old_path), common::ucs2_to_utf8(new_path_abs));
            }
        }

        ctx->complete(epoc::error_none);
    }

    // The translation of one guest address says nothing about the next page.
    // Validate the entire range, then copy page by page: adjacent guest pages
    // need not have adjacent host backing. These IPC handlers run synchronously
    // on the emulation thread, so the mappings cannot change during the copy.
    static bool file_guest_range(service::ipc_context *ctx, const address start,
        const std::uint32_t length, const bool writable, void *buffer = nullptr) {
        if (!length) {
            return true;
        }
        if (!start || (static_cast<std::uint64_t>(start) + length > (std::uint64_t(1) << 32))) {
            return false;
        }
        auto *model = ctx->msg->own_thr->owning_process()->get_mem_model();
        if (!model) {
            return false;
        }
        auto *memory = ctx->sys->get_memory_system();
        auto *control = memory->get_control();
        const auto page_size = memory->get_page_size();
        const auto asid = model->address_space_id();
        const auto required = writable ? prot_write : prot_read;
        std::uint32_t offset = 0;
        while (offset < length) {
            const auto guest = start + offset;
            const auto *page = control->get_page_info(asid, guest);
            if (!page || !page->host_addr || !(page->perm & required)) {
                return false;
            }
            void *host = control->get_host_pointer(asid, guest);
            if (!host) {
                return false;
            }
            const auto count = std::min<std::uint32_t>(length - offset, page_size - (guest % page_size));
            if (buffer) {
                auto *bytes = static_cast<std::uint8_t *>(buffer) + offset;
                if (writable) {
                    std::memcpy(host, bytes, count);
                } else {
                    std::memcpy(bytes, host, count);
                }
            }
            offset += count;
        }
        return true;
    }

    struct file_io_descriptor {
        address header;
        address data;
        address backing_header;
        std::uint32_t info;
        std::uint32_t backing_info;
    };

    static std::optional<file_io_descriptor> file_data_descriptor(service::ipc_context *ctx,
        const bool writable, const std::uint32_t count, int &error, const int slot = 0) {
        error = epoc::error_bad_descriptor;
        const auto arg_type = static_cast<int>(ctx->msg->args.get_arg_type(slot));
        if (!ctx->sys->get_kernel_system()->is_eka1()
            && (!(arg_type & static_cast<int>(ipc_arg_type::flag_des))
                || (arg_type & static_cast<int>(ipc_arg_type::flag_16b))
                || (writable && (arg_type & static_cast<int>(ipc_arg_type::flag_const))))) {
            return std::nullopt;
        }
        const address header = ctx->msg->args.args[slot];
        std::array<std::uint32_t, 3> words {};
        if (!file_guest_range(ctx, header, 4, false, words.data())) {
            return std::nullopt;
        }
        epoc::desc_base descriptor;
        descriptor.info = words[0];
        if (!descriptor.is_valid_descriptor()) {
            return std::nullopt;
        }
        const auto type = descriptor.get_descriptor_type();
        const bool modifiable = (type == epoc::buf) || (type == epoc::ptr) || (type == epoc::ptr_to_buf);
        if (writable && !modifiable) {
            return std::nullopt;
        }
        const std::uint32_t header_size = type == epoc::buf_const ? 4
            : ((type == epoc::ptr_const) || (type == epoc::buf)) ? 8 : 12;
        if (!file_guest_range(ctx, header, header_size, false, words.data())
            || (writable && !file_guest_range(ctx, header, 4, true))) {
            return std::nullopt;
        }
        const auto capacity = modifiable ? words[1] : descriptor.get_length();
        if ((capacity > epoc::descriptor_length_mask) || (descriptor.get_length() > capacity)) {
            return std::nullopt;
        }
        if (count > (writable ? capacity : descriptor.get_length())) {
            error = writable ? epoc::error_overflow : epoc::error_argument;
            return std::nullopt;
        }
        std::uint64_t data_address = 0;
        address backing_header = 0;
        std::uint32_t backing_info = 0;
        switch (type) {
        case epoc::buf_const:
            data_address = static_cast<std::uint64_t>(header) + 4;
            break;
        case epoc::buf:
            data_address = static_cast<std::uint64_t>(header) + 8;
            break;
        case epoc::ptr_const:
            data_address = words[1];
            break;
        case epoc::ptr:
            data_address = words[2];
            break;
        case epoc::ptr_to_buf:
            backing_header = words[2];
            if (!file_guest_range(ctx, backing_header, 4, false, &backing_info)
                || ((backing_info >> 28) != epoc::buf_const)
                || (writable && !file_guest_range(ctx, backing_header, 4, true))) {
                return std::nullopt;
            }
            data_address = static_cast<std::uint64_t>(backing_header) + 4;
            break;
        default:
            return std::nullopt;
        }
        if ((data_address > std::numeric_limits<address>::max())
            || !file_guest_range(ctx, static_cast<address>(data_address), count, writable)) {
            return std::nullopt;
        }
        return file_io_descriptor { header, static_cast<address>(data_address), backing_header, descriptor.info, backing_info };
    }

    static bool file_set_read_length(service::ipc_context *ctx, const file_io_descriptor &descriptor,
        const std::uint32_t count) {
        auto info = (descriptor.info & ~epoc::descriptor_length_mask) | count;
        if (!file_guest_range(ctx, descriptor.header, 4, true, &info)) {
            return false;
        }
        if (descriptor.backing_header) {
            info = (descriptor.backing_info & ~epoc::descriptor_length_mask) | count;
            return file_guest_range(ctx, descriptor.backing_header, 4, true, &info);
        }
        return true;
    }

    // The physical-file VFS currently uses fseek(long). Do not narrow a guest
    // position on hosts where long is smaller than Symbian's 64-bit file offset.
    static constexpr std::uint64_t file_io_max_position = std::numeric_limits<long>::max();

    static std::optional<std::uint64_t> file_io_position(service::ipc_context *ctx, file *vfs_file) {
        if (ctx->msg->function & epoc::fs::ipc_arg_slot2_des) {
            int error;
            const auto packet = file_data_descriptor(ctx, false, sizeof(std::int64_t), error, 2);
            std::int64_t position;
            if (!packet || ((packet->info & epoc::descriptor_length_mask) != sizeof(position))
                || !file_guest_range(ctx, packet->data, sizeof(position), false, &position) || (position < -1)) {
                return std::nullopt;
            }
            if (position != -1) {
                return static_cast<std::uint64_t>(position);
            }
        } else {
            const auto position = ctx->get_argument_value<std::int32_t>(2);
            if (!position) {
                return std::nullopt;
            }
            if ((*position != std::numeric_limits<std::int32_t>::min()) && (*position != -1)) {
                if (*position < 0) {
                    return std::nullopt;
                }
                return static_cast<std::uint64_t>(*position);
            }
        }
        return vfs_file->tell();
    }

    void fs_server_client::file_write(service::ipc_context *ctx) {
        const auto handle = ctx->get_argument_value<std::int32_t>(3);
        const auto length = ctx->get_argument_value<std::int32_t>(1);
        if (!handle || !length || (*length < 0)) {
            ctx->complete(epoc::error_argument);
            return;
        }
        fs_node *node = get_file_node(*handle);
        if (!node || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }
        if (!(node->open_mode & WRITE_MODE)) {
            ctx->complete(epoc::error_access_denied);
            return;
        }
        int descriptor_error;
        const auto descriptor = file_data_descriptor(ctx, false, static_cast<std::uint32_t>(*length), descriptor_error);
        if (!descriptor) {
            ctx->complete(descriptor_error);
            return;
        }

        auto *vfs_file = static_cast<file *>(node->vfs_node.get());
        const auto position = file_io_position(ctx, vfs_file);
        if (!position || (*position > file_io_max_position)) {
            ctx->complete(epoc::error_argument);
            return;
        }
        const auto size = vfs_file->size();
        if (size > file_io_max_position) {
            ctx->complete(epoc::error_general);
            return;
        }
        // RFile::Write at a position beyond EOF appends at EOF. OpenC is
        // responsible for extending the file when implementing POSIX holes.
        const auto write_position = std::min(*position, size);
        if (static_cast<std::uint64_t>(*length) > file_io_max_position - write_position) {
            ctx->complete(epoc::error_argument);
            return;
        }
        // A zero-length write must not extend the file or inspect a null payload.
        if (!*length) {
            ctx->complete(epoc::error_none);
            return;
        }

        if (vfs_file->seek(write_position, file_seek_mode::beg) != write_position) {
            ctx->complete(epoc::error_general);
            return;
        }
        std::array<std::uint8_t, 64 * 1024> data;
        const auto length_bytes = static_cast<std::uint32_t>(*length);
        std::uint32_t offset = 0;
        while (offset < length_bytes) {
            const auto count = std::min<std::uint32_t>(length_bytes - offset, data.size());
            if (!file_guest_range(ctx, descriptor->data + offset, count, false, data.data())) {
                ctx->complete(epoc::error_bad_descriptor);
                return;
            }
            if (vfs_file->write_file(data.data(), 1, count) != count) {
                ctx->complete(epoc::error_write);
                return;
            }
            offset += count;
        }
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_read(service::ipc_context *ctx) {
        const auto handle = ctx->get_argument_value<std::int32_t>(3);
        const auto length = ctx->get_argument_value<std::int32_t>(1);
        if (!handle || !length || (*length < 0)) {
            ctx->complete(epoc::error_argument);
            return;
        }
        fs_node *node = get_file_node(*handle);
        if (!node || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }
        int descriptor_error;
        const auto descriptor = file_data_descriptor(ctx, true, static_cast<std::uint32_t>(*length), descriptor_error);
        if (!descriptor) {
            ctx->complete(descriptor_error);
            return;
        }
        auto *vfs_file = static_cast<file *>(node->vfs_node.get());
        const auto position = file_io_position(ctx, vfs_file);
        if (!position || (*position > file_io_max_position)) {
            ctx->complete(epoc::error_argument);
            return;
        }
        if (vfs_file->seek(*position, file_seek_mode::beg) != *position) {
            ctx->complete(epoc::error_general);
            return;
        }
        const auto size = vfs_file->size();
        if (size > file_io_max_position) {
            ctx->complete(epoc::error_general);
            return;
        }
        // Reading at or beyond EOF succeeds with an empty descriptor. Subtract
        // only after this comparison: unsigned size-position used to underflow.
        const auto count = static_cast<std::uint32_t>(*position >= size ? 0
            : std::min<std::uint64_t>(*length, size - *position));
        std::array<std::uint8_t, 64 * 1024> data;
        std::uint32_t offset = 0;
        while (offset < count) {
            const auto requested = std::min<std::uint32_t>(count - offset, data.size());
            const auto read = vfs_file->read_file(data.data(), 1, requested);
            if ((read > requested) || ((read < requested) && (*position + offset + read < vfs_file->size()))) {
                ctx->complete(epoc::error_general);
                return;
            }
            if (!file_guest_range(ctx, descriptor->data + offset, static_cast<std::uint32_t>(read), true, data.data())) {
                ctx->complete(epoc::error_bad_descriptor);
                return;
            }
            offset += static_cast<std::uint32_t>(read);
            if (read < requested) {
                break;
            }
        }
        if (!file_set_read_length(ctx, *descriptor, offset)) {
            ctx->complete(epoc::error_bad_descriptor);
            return;
        }
        ctx->complete(epoc::error_none);
    }

    struct fs_file_mapping : epoc::ref_count_object {
        fs_node *source_;
        kernel::chunk *chunk_;
        void *backing_;
        std::size_t size_;

        fs_file_mapping(fs_node *source, kernel::chunk *chunk, void *backing, const std::size_t size,
            file_attrib *attrib)
            : source_(source), chunk_(chunk), backing_(backing), size_(size) {
            source_->ref();
            attrib->increment_use(source_->process);
        }

        ~fs_file_mapping() override {
            chunk_->get_kernel_object_owner()->destroy(chunk_);
            source_->deref();
            common::unmap_memory(backing_, size_);
        }
    };

    struct fs_file_map_settings {
        std::uint64_t offset_;
        std::uint64_t size_;
        std::uint32_t file_mode_;
        std::uint32_t map_mode_;
    };
    static_assert(sizeof(fs_file_map_settings) == 24);

    static constexpr std::uint32_t FILE_MAP_WRITE = 1;
    static constexpr std::uint32_t FILE_MAP_REMOVABLE_MEDIA = 2;

    void fs_server_client::file_map_open(service::ipc_context *ctx) {
        const auto settings = ctx->get_argument_data_from_descriptor<fs_file_map_settings>(1);
        if (!settings || (ctx->get_argument_max_data_size(2) < sizeof(address))
            || (ctx->get_argument_max_data_size(3) < sizeof(epoc::handle))) {
            ctx->complete(epoc::error_argument);
            return;
        }

        if (settings->map_mode_ & ~(FILE_MAP_WRITE | FILE_MAP_REMOVABLE_MEDIA)) {
            ctx->complete(epoc::error_argument);
            return;
        }
        // Writable mappings need shared file-cache coherence, not a private copy.
        if (settings->map_mode_ & FILE_MAP_WRITE) {
            ctx->complete(epoc::error_not_supported);
            return;
        }

        const auto page_size = ctx->sys->get_memory_system()->get_page_size();
        if (!settings->size_ || (settings->offset_ % page_size)
            || (settings->size_ > std::numeric_limits<std::int32_t>::max() - page_size)) {
            ctx->complete(epoc::error_argument);
            return;
        }

        int source_handle = 0;
        const bool opened_by_name = (ctx->msg->function & 0xFF) == epoc::fs_msg_file_map_open_name;
        if (opened_by_name) {
            const auto path = ctx->get_argument_value<std::u16string>(0);
            if (!path) {
                ctx->complete(epoc::error_argument);
                return;
            }
            source_handle = new_node(ctx->sys->get_io_system(), ctx->msg->own_thr,
                get_full_symbian_path(ss_path, *path), settings->file_mode_);
            if (source_handle <= 0) {
                ctx->complete(source_handle);
                return;
            }
        } else {
            source_handle = ctx->get_argument_value<std::int32_t>(0).value_or(0);
        }

        auto finish = [&](const std::int32_t result) {
            if (opened_by_name) {
                obj_table_.remove(source_handle);
            }
            ctx->complete(result);
        };
        fs_node *source = get_file_node(source_handle);
        if (!source || source->vfs_node->type != io_component_type::file) {
            finish(epoc::error_bad_handle);
            return;
        }

        auto *source_file = static_cast<file *>(source->vfs_node.get());
        if (!(source->open_mode & READ_MODE)) {
            finish(epoc::error_access_denied);
            return;
        }
        const auto drive = ctx->sys->get_io_system()->get_drive_entry(char16_to_drive(source_file->file_name()[0]));
        if (drive && (drive->attribute & io_attrib_removeable) && !(settings->map_mode_ & FILE_MAP_REMOVABLE_MEDIA)) {
            finish(epoc::error_not_supported);
            return;
        }
        if (settings->offset_ >= source_file->size()
            || settings->size_ > source_file->size() - settings->offset_) {
            finish(epoc::error_argument);
            return;
        }

        const std::size_t mapped_size = common::align(static_cast<std::size_t>(settings->size_), page_size);
        void *backing = common::map_memory(mapped_size);
        if (!backing || !common::commit(backing, mapped_size, prot_read_write)) {
            if (backing) {
                common::unmap_memory(backing, mapped_size);
            }
            finish(epoc::error_no_memory);
            return;
        }

        auto *kern = ctx->sys->get_kernel_system();
        auto *process = ctx->msg->own_thr->owning_process();
        auto *chunk = kern->create<kernel::chunk>(ctx->sys->get_memory_system(), process, "FileMapping", 0,
            mapped_size, mapped_size, prot_read, kernel::chunk_type::normal,
            kernel::chunk_access::local, kernel::chunk_attrib::anonymous, 0, false, 0, backing);
        if (!chunk || !chunk->valid()) {
            if (chunk) {
                kern->destroy(chunk);
            }
            common::unmap_memory(backing, mapped_size);
            finish(epoc::error_no_memory);
            return;
        }

        const auto read = source_file->read_file(settings->offset_, backing, 1, static_cast<std::uint32_t>(settings->size_));
        if (read != settings->size_) {
            kern->destroy(chunk);
            common::unmap_memory(backing, mapped_size);
            finish(epoc::error_general);
            return;
        }

        auto &attrib = server<fs_server>()->attribs[canonical_file_attrib_path(source_file->file_name())];
        auto *mapping = make_new<fs_file_mapping>(source, chunk, backing, mapped_size, &attrib);
        const auto handle = obj_table_.add(mapping);
        const address base = chunk->base(process).ptr_address();
        int error = epoc::error_none;
        if (!ctx->write_data_to_descriptor_argument(2, base, &error)
            || !ctx->write_data_to_descriptor_argument(3, handle, &error)) {
            obj_table_.remove(handle);
            finish(error);
            return;
        }
        finish(epoc::error_none);
    }

    void fs_server_client::file_map_flush(service::ipc_context *ctx) {
        const auto handle = ctx->get_argument_value<std::int32_t>(3).value_or(0);
        ctx->complete(dynamic_cast<fs_file_mapping *>(obj_table_.get_raw(handle))
            ? epoc::error_none : epoc::error_bad_handle);
    }

    void fs_server_client::file_close(service::ipc_context *ctx) {
        std::optional<std::int32_t> handle_res = ctx->get_argument_value<std::int32_t>(3);

        if (!handle_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        if (dynamic_cast<fs_file_mapping *>(obj_table_.get_raw(*handle_res))) {
            obj_table_.remove(*handle_res);
            ctx->complete(epoc::error_none);
            return;
        }

        fs_node *node = get_file_node(*handle_res);

        if (node == nullptr || node->vfs_node->type != io_component_type::file) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        file *vfs_file = reinterpret_cast<file *>(node->vfs_node.get());

        // Reset its status, so seek back, this is just in case it got used again
        vfs_file->flush();
        vfs_file->seek(0, file_seek_mode::beg);

        obj_table_.remove(*handle_res);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_open(service::ipc_context *ctx) {
        new_file_subsession(ctx, exist_mode_neccessary, false);
    }

    void fs_server_client::file_replace(service::ipc_context *ctx) {
        new_file_subsession(ctx, exist_mode_dont_care, true);
    }

    void fs_server_client::file_temp(service::ipc_context *ctx) {
        auto dir_create = ctx->get_argument_value<std::u16string>(0);

        if (!dir_create) {
            ctx->complete(epoc::error_argument);
            return;
        }

        io_system *io = ctx->sys->get_io_system();
        utf16_str full_path = get_full_symbian_path(ss_path, dir_create.value());

        if (!io->exist(full_path)) {
            LOG_TRACE(SERVICE_EFSRV, "Directory for temp file not exists", common::ucs2_to_utf8(full_path));

            ctx->complete(epoc::error_path_not_found);
            return;
        }

        symfile temp_file = server<fs_server>()->get_temp_file(full_path);

        if (!temp_file) {
            LOG_ERROR(SERVICE_EFSRV, "Can't create a temp file in {}", common::ucs2_to_utf8(full_path));
            ctx->complete(epoc::error_general);
            return;
        }

        full_path = temp_file->file_name();

        temp_file->close();

        LOG_INFO(SERVICE_EFSRV, "Opening temp file: {}", common::ucs2_to_utf8(full_path));
        int handle = new_node(ctx->sys->get_io_system(), ctx->msg->own_thr, full_path,
            *ctx->get_argument_value<std::int32_t>(1), true, true);

        if (handle <= 0) {
            ctx->complete(handle);
            return;
        }

        LOG_TRACE(SERVICE_EFSRV, "Handle opened: {}", handle);

        ctx->write_data_to_descriptor_argument<int>(3, handle);

        // Arg2 take the temp path
        const utf16_str guest_path = eka2l1::transform_separators<char16_t>(
            full_path, true, eka2l1::get_separator_16);
        ctx->write_arg(2, guest_path);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_create(service::ipc_context *ctx) {
        new_file_subsession(ctx, exist_mode_must_not, true);
    }

    void fs_server_client::file_duplicate(service::ipc_context *ctx) {
        std::int32_t target_handle = *ctx->get_argument_value<std::int32_t>(0);
        fs_node *node = get_file_node(target_handle);

        if (!node) {
            ctx->complete(epoc::error_not_found);
            return;
        }

        const epoc::handle dup_handle = obj_table_.add(node);

        file *f = reinterpret_cast<file *>(node->vfs_node.get());

        auto &node_attrib = server<fs_server>()->attribs[
            canonical_file_attrib_path(f->file_name())];
        node_attrib.increment_use(node->process);

        ctx->write_data_to_descriptor_argument<epoc::handle>(3, dup_handle);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_adopt(service::ipc_context *ctx) {
        LOG_TRACE(SERVICE_EFSRV, "Fs::FileAdopt stubbed");

        ctx->write_data_to_descriptor_argument<std::uint32_t>(3, ctx->get_argument_value<std::uint32_t>(0).value());
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_att(service::ipc_context *ctx) {
        std::int32_t target_handle = *ctx->get_argument_value<std::int32_t>(3);

        if (!target_handle) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(target_handle);

        if (!node) {
            ctx->complete(epoc::error_not_found);
            return;
        }

        file *f = reinterpret_cast<file *>(node->vfs_node.get());
        io_system *io = ctx->sys->get_io_system();

        std::optional<entry_info> info = io->get_entry_info(f->file_name());
        assert(info);

        const std::uint32_t attrib = epoc::fs::build_attribute_from_entry_info(info.value());
        ctx->write_data_to_descriptor_argument(0, attrib);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::file_set_att(service::ipc_context *ctx) {
        std::int32_t target_handle = *ctx->get_argument_value<std::int32_t>(3);

        if (!target_handle) {
            ctx->complete(epoc::error_argument);
            return;
        }

        fs_node *node = get_file_node(target_handle);

        if (!node) {
            ctx->complete(epoc::error_not_found);
            return;
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::read_file_section(service::ipc_context *ctx) {
        kernel_system *kern = ctx->sys->get_kernel_system();

        std::uint64_t position = 0;
        bool old_read_model = kern->is_eka1();

        std::uint32_t filename_slot = (old_read_model ? 0 : 1);
        std::optional<std::u16string> target_file_path = ctx->get_argument_value<std::u16string>(filename_slot);

        if (!target_file_path) {
            ctx->complete(epoc::error_argument);
            return;
        }

        if (eka2l1::filename(target_file_path.value()).empty()) {
            ctx->complete(epoc::error_bad_name);
            return;
        }

        if (!old_read_model && (ctx->msg->function & 0x00040000)) {
            // The position is in a package
            auto position_package = ctx->get_argument_data_from_descriptor<std::uint64_t>(2);

            if (!position_package) {
                ctx->complete(epoc::error_argument);
                return;
            }

            position = position_package.value();
        } else {
            if (old_read_model) {
                position = ctx->get_argument_value<std::uint32_t>(1).value();
            } else {    
                position = ctx->get_argument_value<std::uint32_t>(2).value();
            }
        }

        target_file_path.value() = get_full_symbian_path(ss_path, target_file_path.value());

        if (!check_path_capabilities_pass(target_file_path.value(), ctx->msg->own_thr->owning_process(), epoc::fs::private_comp_access_policy, epoc::fs::sys_read_only_access_policy, epoc::fs::resource_read_only_access_policy)) {
            ctx->complete(epoc::error_permission_denied);
            return;
        }

        // Get the buffer length
        std::uint32_t buffer_length = 0;
        if (old_read_model) {
            buffer_length = ctx->get_argument_value<std::uint32_t>(2).value();
        } else {
            buffer_length = ctx->get_argument_value<std::uint32_t>(3).value();
        }

        // Open the file, one time only, from VFS
        io_system *io = ctx->sys->get_io_system();
        symfile target_file = io->open_file(target_file_path.value(), READ_MODE | BIN_MODE);

        if (!target_file || !target_file->valid()) {
            // Exist but not a file
            if (io->exist(target_file_path.value())) {
                ctx->complete(epoc::error_bad_name);
                return;
            }

            ctx->complete(epoc::error_path_not_found);
            return;
        }

        std::uint32_t slot_to_set_length = (old_read_model ? 3 : 0);
        std::uint8_t *buffer = ctx->get_descriptor_argument_ptr(slot_to_set_length);

        if (!buffer) {
            ctx->complete(epoc::error_argument);
            target_file->close();
            return;
        }

        target_file->seek(position, eka2l1::file_seek_mode::beg);
        const std::size_t readed_size = target_file->read_file(buffer, buffer_length, 1);
        target_file->close();

        if (!ctx->set_descriptor_argument_length(slot_to_set_length, static_cast<std::uint32_t>(readed_size))) {
            ctx->complete(epoc::error_argument);
            return;
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::new_file_subsession(service::ipc_context *ctx, const exist_check_mode existence,
        bool overwrite, bool temporary) {
        std::optional<std::u16string> name_res = ctx->get_argument_value<std::u16string>(0);
        std::optional<std::int32_t> open_mode_res = ctx->get_argument_value<std::int32_t>(1);

        if (!name_res || !open_mode_res) {
            ctx->complete(epoc::error_argument);
            return;
        }

        *name_res = get_full_symbian_path(ss_path, *name_res);
        std::string name_utf8 = common::ucs2_to_utf8(*name_res);

        io_system *io = ctx->sys->get_io_system();

        {
            auto file_dir = eka2l1::file_directory(*name_res);

            // A process's own private directory exists on a device, so a missing file
            // there reports KErrNotFound. Here it only appears once something has
            // written to it, and the guest gets KErrPathNotFound instead -- a
            // different error, which fallback paths do not recognise. The metadata
            // server reads its schema from C:\private\200009F3\ and only falls back
            // to the ROM copy on KErrNotFound, so it dies on a clean drive.
            if (!io->exist(file_dir) && is_process_own_private_dir(ctx->msg->own_thr->owning_process(), file_dir)) {
                io->create_directories(file_dir);
            }

            // Do a check to return epoc::error_path_not_found
            if (!io->exist(file_dir)) {
                LOG_TRACE(SERVICE_EFSRV, "Base directory of file {} not found", name_utf8);

                ctx->complete(epoc::error_path_not_found);
                return;
            }
        }

        const bool is_it_avail = io->exist(name_res.value());

        if (is_it_avail && (existence == exist_mode_must_not)) {
            LOG_ERROR(SERVICE_EFSRV, "Trying to open existing file: {}, while the requirement open mode forbidded this!",
                name_utf8);

            ctx->complete(epoc::error_already_exists);
            return;
        }

        if (!is_it_avail && (existence == exist_mode_neccessary)) {
            LOG_ERROR(SERVICE_EFSRV, "Trying to open a non-existent file: {} while the open mode requires its availbility!",
                name_utf8);

            ctx->complete(epoc::error_not_found);
            return;
        }

        LOG_INFO(SERVICE_EFSRV, "Opening file: {}, raw mode {}", name_utf8, open_mode_res.value());
        int handle = new_node(ctx->sys->get_io_system(), ctx->msg->own_thr, *name_res,
            *open_mode_res, overwrite, temporary);

        if (handle <= 0) {
            ctx->complete(handle);
            return;
        }

        LOG_TRACE(SERVICE_EFSRV, "Handle opened: {}", handle);

        ctx->write_data_to_descriptor_argument<int>(3, handle);
        ctx->complete(epoc::error_none);
    }

    int fs_server_client::new_node(io_system *io, kernel::thread *sender, std::u16string name, int org_mode, bool overwrite, bool temporary, bool ignore_caps) {
        if (name.empty() || (eka2l1::is_separator(name.back()))) {
            LOG_ERROR(SERVICE_EFSRV, "Path is invalid!");
            return epoc::error_bad_name;
        }

        int real_mode = org_mode & ~(epoc::fs::file_stream_text | epoc::fs::file_read_async_all | epoc::fs::file_big_size);
        epoc::fs::file_mode share_mode = static_cast<epoc::fs::file_mode>(real_mode & 0b11);

        // Fetch open mode
        int access_mode = -1;

        if (!(real_mode & epoc::fs::file_stream_text)) {
            access_mode = BIN_MODE;
        } else {
            access_mode = 0;
        }

        if (real_mode & epoc::fs::file_write) {
            if (!overwrite) {
                access_mode |= (READ_MODE | WRITE_MODE);
            } else {
                access_mode |= WRITE_MODE;
            }
        } else {
            // Since EFileRead = 0, they default to read mode if nothing is specified more
            // Note also the document said mode is automatically set to write with Filereplace (overwrite boolean)
            access_mode |= (overwrite ? WRITE_MODE : READ_MODE);
        }

        if ((access_mode & WRITE_MODE) && (share_mode == epoc::fs::file_share_readers_only)) {
            return epoc::error_argument;
        }

        kernel::process *own_pr = sender->owning_process();
        kernel::uid own_pr_uid = own_pr->unique_id();

        // Check capabilities
        if (!ignore_caps) {
            if (!check_path_capabilities_pass(name, own_pr, epoc::fs::private_comp_access_policy, (access_mode & WRITE_MODE) ? epoc::fs::sys_resource_modify_access_policy : epoc::fs::sys_read_only_access_policy,
                    (access_mode & WRITE_MODE) ? epoc::fs::sys_resource_modify_access_policy : epoc::fs::resource_read_only_access_policy)) {
                LOG_ERROR(SERVICE_EFSRV, "New file node fails capabilities requirements with path={}, process UID=0x{:X}", common::ucs2_to_utf8(name), own_pr_uid);
                return epoc::error_permission_denied;
            }
        }

        // Check the attribute first
        fs_node *new_node = server<fs_server>()->make_new<fs_node>();
        auto &node_attrib = server<fs_server>()->attribs[
            canonical_file_attrib_path(name)];

        if (node_attrib.is_exlusive()) {
            // Check if we can open it
            if (node_attrib.owner != own_pr_uid) {
                // Access denied
                return epoc::error_in_use;
            }
        }

        node_attrib.increment_use(own_pr_uid);

        if (share_mode == epoc::fs::file_share_exclusive) {
            // Try to claim and return denied if we can't
            if (!node_attrib.claim_exclusive(own_pr_uid)) {
                return epoc::error_in_use;
            }
        }

        //======================= CHECK COMPARE MODE ===============================

        if (node_attrib.is_readable_and_writeable() && !node_attrib.is_optional()) {
            if (share_mode == epoc::fs::file_share_readers_only) {
                // Hell no.
                return epoc::error_access_denied;
            }
        }

        if (node_attrib.is_readonly() && ((share_mode == epoc::fs::file_share_any) || (share_mode == epoc::fs::file_share_readers_or_writers))) {
            return epoc::error_access_denied;
        }

        //======================= PROMOTE MODE ==============================
        // TODO

        //======================= DO OPEN AND FILL ==========================
        new_node->vfs_node = io->open_file(name, access_mode);

        if (!new_node->vfs_node) {
            LOG_TRACE(SERVICE_EFSRV, "Can't open file {}", common::ucs2_to_utf8(name));
            return epoc::error_not_found;
        }

        new_node->mix_mode = real_mode;
        new_node->open_mode = access_mode;
        new_node->process = own_pr_uid;
        new_node->temporary = temporary;
        new_node->serv = server<fs_server>();

        return obj_table_.add(new_node);
    }
}
