/*
 * Copyright (c) 2022 EKA2L1 Team.
 * 
 * This file is part of EKA2L1 project.
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

#include <drivers/video/video.h>

#include <common/platform.h>

#if !EKA2L1_PLATFORM(IOS)
#include <drivers/video/backend/ffmpeg/video_player_ffmpeg.h>
#endif

namespace eka2l1::drivers {
    video_player_instance new_best_video_player(audio_driver *drv) {
#if EKA2L1_PLATFORM(IOS)
        // Stage-0 iOS build has no video backend wired up yet; see task 0.5.
        (void)drv;
        return nullptr;
#else
        return std::make_unique<video_player_ffmpeg>(drv);
#endif
    }
}