/* Copyright (c) 2026 EKA2L1 Team. GPL version 3 or later. */
#include "../scdv/inc/cdsb.h"
#include <hal.h>

CBase::~CBase() {}
void operator delete(void* pointer) noexcept { User::Free(pointer); }
void operator delete(void* pointer, unsigned) noexcept { User::Free(pointer); }
extern "C" void __cxa_pure_virtual() { User::Invariant(); }

extern "C" TInt FramebufferStride(TInt, TInt screen, TInt mode);
extern "C" void PresentFramebuffer(TInt, TInt screen, TInt count, const TRect* rects);

namespace {
class DirectBitmap final : public CDirectScreenBitmap {
    TInt screen_;
    TUint8* data_ = nullptr;
    TInt stride_ = 0;
    TRect rectangle_;
public:
    explicit DirectBitmap(TInt screen) : screen_(screen) {}
    ~DirectBitmap() override { Close(); }
    TInt Create(const TRect& rectangle, TSettingsFlags flags) override {
        Close();
        if (rectangle.IsEmpty() || rectangle.iTl.iX < 0 || rectangle.iTl.iY < 0) return KErrArgument;
        const TInt encoded_screen = (static_cast<TUint>(flags) >> 28) & 7;
        if (encoded_screen) screen_ = encoded_screen;
        TInt address = 0, offset = 0;
        TInt result = HAL::Get(screen_, HAL::EDisplayMemoryAddress, address);
        if (result != KErrNone) return result;
        result = HAL::Get(screen_, HAL::EDisplayOffsetToFirstPixel, offset);
        if (result != KErrNone) return result;
        stride_ = FramebufferStride(0, screen_, EColor16MA);
        if (!address || stride_ <= 0 || rectangle.iBr.iX > stride_ / 4) return KErrArgument;
        rectangle_ = rectangle;
        data_ = reinterpret_cast<TUint8*>(address) + offset
              + rectangle.iTl.iY * stride_ + rectangle.iTl.iX * 4;
        return KErrNone;
    }
    TInt BeginUpdate(TAcceleratedBitmapInfo& info) override {
        if (!data_) return KErrNotReady;
        info.iDisplayMode = EColor16MA;
        info.iAddress = data_;
        info.iSize = rectangle_.Size();
        info.iLinePitch = stride_;
        info.iPixelShift = 5;
        return KErrNone;
    }
    void EndUpdate(TRequestStatus& complete) override { EndUpdate(rectangle_, complete); }
    void EndUpdate(const TRect& rectangle, TRequestStatus& complete) override {
        TInt result = KErrNotReady;
        if (data_) {
            if (rectangle.iTl.iX < rectangle_.iTl.iX || rectangle.iTl.iY < rectangle_.iTl.iY ||
                rectangle.iBr.iX > rectangle_.iBr.iX || rectangle.iBr.iY > rectangle_.iBr.iY) {
                result = KErrArgument;
            } else {
                PresentFramebuffer(0, screen_, 1, &rectangle);
                result = KErrNone;
            }
        }
        TRequestStatus* request = &complete;
        User::RequestComplete(request, result);
    }
    void Close() override { data_ = nullptr; stride_ = 0; }
};
}

extern "C" __attribute__((visibility("default")))
CDirectScreenBitmap* CreateDirectBitmap(TInt screen) { return new(ELeave) DirectBitmap(screen); }
extern "C" __attribute__((visibility("default")))
CDirectScreenBitmap* CreateDefaultDirectBitmap() { return CreateDirectBitmap(0); }
