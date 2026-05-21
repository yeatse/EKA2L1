// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// UIKit shell hosting the CAEAGLLayer-backed view that drives the emulator.
// Swift wraps this through UIViewControllerRepresentable (see
// App/EmulatorView.swift).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EmulatorViewController : UIViewController

- (instancetype)initWithUID:(uint32_t)uid;

@end

NS_ASSUME_NONNULL_END
