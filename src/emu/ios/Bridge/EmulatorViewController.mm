// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulatorViewController.h"
#import "IosEmulator.h"

#import <QuartzCore/CAEAGLLayer.h>

// CAEAGLLayer-backed view. Touch events go to IosEmulator (task 2.8) and
// layout changes republish the layer + framebuffer size to emu_window_ios
// via -[EKA2L1Emulator attachLayer:pixelSize:scale:].
@interface EAGL2L1View : UIView
@property(nonatomic, assign) BOOL surfaceReady;
@end

@implementation EAGL2L1View

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (CAEAGLLayer *)eaglLayer {
    return (CAEAGLLayer *)self.layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentScaleFactor = UIScreen.mainScreen.nativeScale;
        self.multipleTouchEnabled = NO; // single-touch for stage 2 scope
        self.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
        self.eaglLayer.opaque = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat scale = self.contentScaleFactor;
    CGSize bounds = self.bounds.size;
    CGSize pixels = CGSizeMake(bounds.width * scale, bounds.height * scale);
    if (pixels.width <= 0 || pixels.height <= 0) {
        return;
    }

    [[EKA2L1Emulator shared] attachLayer:self.eaglLayer
                              pixelSize:pixels
                                   scale:scale];
    self.surfaceReady = YES;
}

#pragma mark - Touches → pointer events

- (EKA2L1PointerPhase)phaseForTouchPhase:(UITouchPhase)phase {
    switch (phase) {
        case UITouchPhaseBegan:     return EKA2L1PointerPhaseBegan;
        case UITouchPhaseMoved:     return EKA2L1PointerPhaseMoved;
        case UITouchPhaseStationary:return EKA2L1PointerPhaseMoved;
        case UITouchPhaseEnded:     return EKA2L1PointerPhaseEnded;
        case UITouchPhaseCancelled: return EKA2L1PointerPhaseCancelled;
        default:                    return EKA2L1PointerPhaseCancelled;
    }
}

- (void)dispatchTouches:(NSSet<UITouch *> *)touches {
    CGFloat scale = self.contentScaleFactor;
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        [[EKA2L1Emulator shared] submitPointerEventAtX:point.x * scale
                                                     y:point.y * scale
                                                 phase:[self phaseForTouchPhase:touch.phase]
                                             pointerId:(uintptr_t)touch];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches];
}

@end

@interface EmulatorViewController ()
@property(nonatomic, assign) uint32_t pendingUID;
@property(nonatomic, strong) EAGL2L1View *gameView;
@end

@implementation EmulatorViewController

- (instancetype)initWithUID:(uint32_t)uid {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _pendingUID = uid;
    }
    return self;
}

- (void)loadView {
    EAGL2L1View *view = [[EAGL2L1View alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
    self.gameView = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Make sure the layer has at least one valid layout pass behind it so
    // attachLayer:pixelSize:scale: has been called with non-zero dimensions
    // before we kick off the app.
    [self.gameView setNeedsLayout];
    [self.gameView layoutIfNeeded];
    if (self.gameView.surfaceReady) {
        [[EKA2L1Emulator shared] launchAppWithUID:self.pendingUID];
        [[EKA2L1Emulator shared] resume];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[EKA2L1Emulator shared] pause];
}

@end
