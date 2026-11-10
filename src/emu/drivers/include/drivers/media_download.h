/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPL version 3 or later.
 */

#pragma once

#include <atomic>
#include <memory>
#include <string>

namespace eka2l1::drivers {
    // The transfer retains its temporary file until the worker and player release it.
    class media_download final {
    public:
        enum class result {
            pending, complete, cancelled, invalid_url, network_error,
            timeout, http_error, tls_error, file_error, resource_error, not_supported
        };

        static std::shared_ptr<media_download> start(std::string url);
        ~media_download();
        void cancel() noexcept { cancelled_.store(true, std::memory_order_relaxed); }
        result status() const noexcept { return result_.load(std::memory_order_acquire); }

        // Read these only after status() is no longer pending.
        const std::string &path() const { return path_; }
        const std::string &error() const { return error_; }
        long http_status() const { return http_status_; }

    private:
        explicit media_download(std::string url, std::string ca_bundle);
        void run();

        std::string url_;
        std::string ca_bundle_;
        std::string path_;
        std::string error_;
        long http_status_ = 0;
        std::atomic<bool> cancelled_{false};
        std::atomic<result> result_{result::pending};
    };
}
