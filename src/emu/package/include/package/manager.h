/*
 * Copyright (c) 2018 EKA2L1 Team.
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
#pragma once

#include <common/types.h>
#include <package/registry.h>
#include <package/common.h>

#include <atomic>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace eka2l1 {
    class io_system;

    namespace loader {
        struct sis_controller;
        struct sis_registry_tree;

        using show_text_func = std::function<bool(const char *, const bool)>;
        using choose_lang_func = std::function<int(const int *langs, const int count)>;
        using var_value_resolver_func = std::function<std::int32_t(std::uint32_t)>;
    }

    namespace package {
        enum installation_result {
            installation_result_success = 0,
            installation_result_aborted = 1,
            installation_result_invalid = 2
        };
    }

    namespace config {
        struct state;
    }

    /*! \brief Managing apps. */
    namespace manager {
        using uid = uint32_t;

        struct controller_info {
            std::uint8_t *data_;
            std::size_t size_;
        };

        using object_map_type = std::multimap<uid, package::object>;

        // A package manager, serves for managing packages
        class packages {
            object_map_type objects_;
            drive_number residing_;

            io_system *sys;
            config::state *conf;

        protected:
            void traverse_tree_and_add_packages(loader::sis_registry_tree &tree);
            void install_sis_stubs();

            // Remove "<drive>:\private\<sid>\" from every writable drive, the data
            // directory an executable that was just uninstalled owned.
            void remove_private_directories(const epoc::uid sid);

            // Files an installed package owns that its new version does not, deleted
            // so an upgrade does not keep dragging the old version's leftovers along.
            void remove_stale_files(package::object &installed, const package::object &replacement);

        public:
            mutable std::mutex lockdown;

            loader::show_text_func show_text;
            loader::choose_lang_func choose_lang;
            loader::var_value_resolver_func var_resolver;

            explicit packages(io_system *sys, config::state *conf, const drive_number residing = drive_c);
            bool installed(const uid pkg_uid);

            void migrate_legacy_registries();
            void load_registries();

            const std::size_t package_count() const {
                return objects_.size();
            }

            object_map_type::iterator begin() {
                return objects_.begin();
            }

            object_map_type::iterator end() {
                return objects_.end();
            }

            // No thread safe
            package::object *package(const uid app_uid, const std::int32_t index = 0);

            /**
             * @brief Find the package that installed an executable with this secure ID.
             *
             * An app's UID3 is the SID of the executable it runs from, so this identifies
             * the package owning an app even though Symbian does not require the package's
             * UID to match (Opera Mobile registers app 0x2002AA96 from package 0x2002AA97).
             * Registries written before executable SIDs were resolved hold none, in which
             * case package_owning_file() is the way in.
             *
             * @param secure_id Secure ID to look for; 0 never matches.
             * @returns The owning package, or nullptr when no package claims the SID.
             */
            package::object *package_owning_executable(const uid secure_id);

            /**
             * @brief Find the package that installed a given file.
             *
             * Symbian does not require a package's UID to match the UID3 of the app it
             * installs (Opera Mobile registers app 0x2002AA96 from package 0x2002AA97),
             * so a frontend that only knows an app can't reliably find its package by
             * UID. The app binary it launches from does identify the package.
             *
             * @param file_path Virtual path of the file, matched case-insensitively. When no
             *                  package holds that exact path, a package holding the same file
             *                  name on the same drive answers instead — the directory applist
             *                  rebuilds for an app rarely matches the installed one — provided
             *                  it is the only package with that name.
             * @returns The owning package, or nullptr when no package claims the file.
             */
            package::object *package_owning_file(const std::u16string &file_path);
            package::object *package(const uid app_uid, const std::u16string package_name, const std::u16string vendor_name);
            std::vector<package::object *> augmentations(const uid app_uid);
            std::vector<package::object *> dependents(const uid app_uid);
            std::vector<uid> installed_uids() const;

            bool controller(const uid app_uid, const std::uint32_t package_index, const std::uint32_t controller_offset,
                loader::sis_controller &controller_output);

            bool add_package(package::object &pkg, const controller_info *controller_info);
            bool save_package(package::object &pkg);
            bool uninstall_package(package::object &pkg);
            bool remove_registeration(package::object &pkg);

            package::installation_result install_package(const std::u16string &path, const drive_number drive, progress_changed_callback progress_cb = nullptr,
                cancel_requested_callback cancel_cb = nullptr, const bool silent = false);
        };
    }
}
