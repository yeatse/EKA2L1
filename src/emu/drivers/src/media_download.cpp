#include <drivers/media_download.h>

#include <curl/curl.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace eka2l1::drivers {
    media_download::media_download(std::string url, std::string ca_bundle)
        : url_(std::move(url)), ca_bundle_(std::move(ca_bundle)) {
    }

    media_download::~media_download() {
        if (!path_.empty()) {
            std::error_code ignored;
            std::filesystem::remove(std::filesystem::u8path(path_), ignored);
        }
    }

    std::shared_ptr<media_download> media_download::start(std::string url) {
        // URI schemes are case insensitive, but embedded NULs must never be
        // interpreted as a truncated, different URL by libcurl.
        const auto colon = url.find(':');
        if (colon != std::string::npos)
            std::transform(url.begin(), url.begin() + colon, url.begin(), [](unsigned char character) {
                return character >= 'A' && character <= 'Z' ? character + ('a' - 'A') : character;
            });
        const char *ca_bundle = std::getenv("EKA2L1_MEDIA_CA_BUNDLE");
        auto transfer = std::shared_ptr<media_download>(new media_download(std::move(url), ca_bundle ? ca_bundle : ""));
        try {
            std::thread([transfer] { transfer->run(); }).detach();
        } catch (const std::exception &error) {
            transfer->error_ = error.what();
            transfer->result_.store(result::resource_error, std::memory_order_release);
        }
        return transfer;
    }

    static FILE *temporary_file(std::string &path) {
#ifdef _WIN32
        wchar_t directory[MAX_PATH + 1], name[MAX_PATH + 1];
        if (!GetTempPathW(MAX_PATH, directory) || !GetTempFileNameW(directory, L"eka", 0, name))
            return nullptr;
        auto utf8 = std::filesystem::path(name).u8string();
        path.assign(utf8.begin(), utf8.end());
        FILE *file = nullptr;
        _wfopen_s(&file, name, L"w+b");
        return file;
#else
        std::error_code error;
        auto directory = std::filesystem::temp_directory_path(error);
        if (error)
            return nullptr;
        std::string pattern = (directory / "eka-media-XXXXXX").string();
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back(0);
        int descriptor = mkstemp(name.data());
        if (descriptor < 0)
            return nullptr;
        path = name.data();
        FILE *file = fdopen(descriptor, "w+b");
        if (!file)
            close(descriptor);
        return file;
#endif
    }

    void media_download::run() {
        result final_result = result::network_error;
        try {
            // Explicitly reject local-file and other protocol URLs, including
            // redirects. A browser uses WebCore's loader instead of this API.
            if (url_.find('\0') != std::string::npos || (url_.compare(0, 7, "http://") && url_.compare(0, 8, "https://"))) {
                result_.store(result::invalid_url, std::memory_order_release);
                return;
            }
            static std::once_flag once;
            static CURLcode initialization = CURLE_FAILED_INIT;
            std::call_once(once, [] { initialization = curl_global_init(CURL_GLOBAL_DEFAULT); });
            if (initialization != CURLE_OK) {
                result_.store(result::resource_error, std::memory_order_release);
                return;
            }
            std::unique_ptr<FILE, decltype(&fclose)> file(temporary_file(path_), fclose);
            if (!file) {
                result_.store(result::file_error, std::memory_order_release);
                return;
            }
            std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> curl(curl_easy_init(), curl_easy_cleanup);
            if (!curl) {
                result_.store(result::resource_error, std::memory_order_release);
                return;
            }
            char error_buffer[CURL_ERROR_SIZE] = {};
            CURLcode configuration = CURLE_OK;
            auto set_option = [&](CURLoption option, auto value) {
                const auto code = curl_easy_setopt(curl.get(), option, value);
                if (configuration == CURLE_OK)
                    configuration = code;
            };
            set_option(CURLOPT_ERRORBUFFER, error_buffer);
            set_option(CURLOPT_URL, url_.c_str());
            set_option(CURLOPT_NOSIGNAL, 1L);
            set_option(CURLOPT_PROTOCOLS_STR, "http,https");
            set_option(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
            set_option(CURLOPT_FOLLOWLOCATION, 1L);
            set_option(CURLOPT_MAXREDIRS, 5L);
            set_option(CURLOPT_SSL_VERIFYPEER, 1L);
            set_option(CURLOPT_SSL_VERIFYHOST, 2L);
            if (!ca_bundle_.empty())
                set_option(CURLOPT_CAINFO, ca_bundle_.c_str());
            set_option(CURLOPT_CONNECTTIMEOUT, 10L);
            set_option(CURLOPT_TIMEOUT, 120L);
            set_option(CURLOPT_FAILONERROR, 1L);
            set_option(CURLOPT_WRITEDATA, file.get());
            // Keep FILE ownership and fwrite in this module's CRT, including
            // when a Windows libcurl DLL uses a different C runtime.
            set_option(CURLOPT_WRITEFUNCTION,
                +[](char *bytes, std::size_t size, std::size_t count, void *context) -> std::size_t {
                    if (size && count > std::numeric_limits<std::size_t>::max() / size)
                        return 0;
                    return std::fwrite(bytes, 1, size * count, static_cast<FILE *>(context));
                });
            set_option(CURLOPT_NOPROGRESS, 0L);
            set_option(CURLOPT_XFERINFODATA, this);
            set_option(CURLOPT_XFERINFOFUNCTION,
                +[](void *context, curl_off_t, curl_off_t, curl_off_t, curl_off_t) -> int {
                    return static_cast<media_download *>(context)->cancelled_.load(std::memory_order_relaxed);
                });
            // A host libcurl lacking a required security option must fail
            // closed, rather than silently use a weaker transfer policy.
            if (configuration != CURLE_OK) {
                error_ = curl_easy_strerror(configuration);
                result_.store(result::resource_error, std::memory_order_release);
                return;
            }
            CURLcode code = cancelled_.load(std::memory_order_relaxed) ? CURLE_ABORTED_BY_CALLBACK : curl_easy_perform(curl.get());
            curl_easy_getinfo(curl.get(), CURLINFO_RESPONSE_CODE, &http_status_);
            error_ = error_buffer[0] ? error_buffer : curl_easy_strerror(code);
            if (cancelled_.load(std::memory_order_relaxed) || code == CURLE_ABORTED_BY_CALLBACK)
                final_result = result::cancelled;
            else if (code == CURLE_PEER_FAILED_VERIFICATION || code == CURLE_SSL_CACERT_BADFILE || code == CURLE_SSL_ISSUER_ERROR)
                final_result = result::tls_error;
            else if (code == CURLE_OPERATION_TIMEDOUT)
                final_result = result::timeout;
            else if (code == CURLE_HTTP_RETURNED_ERROR || (code == CURLE_OK && http_status_ != 200))
                final_result = result::http_error;
            else if (code == CURLE_WRITE_ERROR)
                final_result = result::file_error;
            else if (code == CURLE_OK)
                final_result = result::complete;
            // Closing completes all writes before publishing the local path.
            if (fclose(file.release()) && final_result == result::complete)
                final_result = result::file_error;
        } catch (const std::exception &error) {
            error_ = error.what();
            final_result = result::resource_error;
        }
        result_.store(final_result, std::memory_order_release);
    }
}
