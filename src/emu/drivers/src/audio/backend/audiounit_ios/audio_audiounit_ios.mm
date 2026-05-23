/*
 * Copyright (c) 2026 EKA2L1 Team.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import <AVFoundation/AVFoundation.h>

#include <common/log.h>
#include <drivers/audio/backend/audiounit_ios/audio_audiounit_ios.h>
#include <drivers/audio/backend/audiounit_ios/stream_audiounit_ios.h>
#include <drivers/audio/backend/baeplat_impl.h>

namespace {

// AVAudioSession is a shared per-process singleton. Configure it on first
// driver instantiation; nothing tears it down explicitly (services come and
// go, the session category persists for the app's lifetime).
void configure_av_audio_session_once() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeDefault
                     options:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err];
        if (err) {
            LOG_WARN(eka2l1::DRIVER_AUD, "AVAudioSession setCategory failed: {}",
                err.localizedDescription.UTF8String ?: "unknown");
            err = nil;
        }
        [session setActive:YES error:&err];
        if (err) {
            LOG_WARN(eka2l1::DRIVER_AUD, "AVAudioSession setActive failed: {}",
                err.localizedDescription.UTF8String ?: "unknown");
        }
    });
}

} // namespace

namespace eka2l1::drivers {
    audiounit_ios_audio_driver::audiounit_ios_audio_driver(const std::uint32_t initial_master_volume,
        const player_type preferred_midi_backend)
        : audio_driver(initial_master_volume, preferred_midi_backend) {
        configure_av_audio_session_once();
    }

    audiounit_ios_audio_driver::~audiounit_ios_audio_driver() {
        BAE_DriverDeactivated(this);
    }

    std::uint32_t audiounit_ios_audio_driver::native_sample_rate() {
        const double r = [AVAudioSession sharedInstance].sampleRate;
        if (r > 0.0) {
            return static_cast<std::uint32_t>(r);
        }
        return 48000;
    }

    std::unique_ptr<audio_output_stream> audiounit_ios_audio_driver::new_output_stream(
        const std::uint32_t sample_rate, const std::uint8_t channels, data_callback callback) {
        return std::unique_ptr<audio_output_stream>(
            new audiounit_ios_output_stream(this, sample_rate, channels, callback));
    }

    std::unique_ptr<audio_input_stream> audiounit_ios_audio_driver::new_input_stream(
        const std::uint32_t sample_rate, const std::uint8_t channels, data_callback callback) {
        return std::unique_ptr<audio_input_stream>(
            new audiounit_ios_input_stream(this, sample_rate, channels, callback));
    }
}
