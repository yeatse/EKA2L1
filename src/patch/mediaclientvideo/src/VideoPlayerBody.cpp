#include <VideoPlayerBody.h>
#include <dispatch.h>
#include <Log.h>

#ifndef EKA2
EXPORT_C TInt E32Dll(TDllReason) {
    return 0;
}
#endif

CVideoPlayerFeedbackHandler::CVideoPlayerFeedbackHandler(MVideoPlayerUtilityObserver &aObserver)
    : iObserver(aObserver)
    , iCurrentState(EVideoPlayerStateIdle) {
    
}

void CVideoPlayerFeedbackHandler::OpenComplete(const TInt aError) {
    if (aError == KErrNone) {
        iCurrentState = EVideoPlayerStateOpened;
    }

    iObserver.MvpuoOpenComplete(aError);
}

void CVideoPlayerFeedbackHandler::PrepareComplete(const TInt aError) {
    if (aError == KErrNone) {
        iCurrentState = EVideoPlayerStatePrepared;
    }

    iObserver.MvpuoPrepareComplete(aError);
}

void CVideoPlayerFeedbackHandler::PlayComplete(const TInt aError) {
    iCurrentState = EVideoPlayerStatePrepared;      // Whatever error it's, gonna stop anyway.
    iObserver.MvpuoPlayComplete(aError);
}

void CVideoPlayerFeedbackHandler::Pause() {
    iCurrentState = EVideoPlayerStatePaused;
}

void CVideoPlayerFeedbackHandler::Stop() {
    iCurrentState = EVideoPlayerStatePrepared;
}

void CVideoPlayerFeedbackHandler::Close() {
    iCurrentState = EVideoPlayerStateIdle;
}

void CVideoPlayerFeedbackHandler::Play() {
    iCurrentState = EVideoPlayerStatePlaying;
}

CVideoPlayerUtility::CBody::CBody(MVideoPlayerUtilityObserver &aObserver, TInt aVersion)
        : CActive(CActive::EPriorityHigh)
        , iFeedbackHandler(aObserver)
        , iActiveWindow(NULL)
        , iActiveWindowHandle(0)
        , iDispatchInstance(NULL)
        , iVideoFps(-1.0f)
        , iVideoBitRate(-1)
        , iAudioBitRate(-1)
        , iCurrentVolume(-1)
        , iCurrentRotation(EVideoRotationNone)
        , iCompleteIdle(NULL)
        , iOpenPoll(NULL)
        , iOpenResult(KErrNone)
        , iPrepareResult(KErrNone)
        , iSourceGeneration(0)
        , iVersion(aVersion)
        , iCallbackGuards(NULL) {
#ifndef MCV_EKA1
    iSurfaceId = TSurfaceId::CreateNullId();
#endif
}

CVideoPlayerUtility::CBody::~CBody() {
    for (TCallbackGuard *guard = iCallbackGuards; guard; guard = guard->iPrevious)
        guard->iOwner = NULL;
    iCallbackGuards = NULL;
    Close();
    Cancel();
    delete iCompleteIdle;
    delete iOpenPoll;
    iWindowInfos.Close();
#ifndef MCV_EKA1
    iDisplayObservers.Close();
#endif
    if (iDispatchInstance) {
        EVideoPlayerDestroy(0, iDispatchInstance);
    }
}

CVideoPlayerUtility::CBody::TCallbackGuard::TCallbackGuard(CBody *aOwner)
    : iOwner(aOwner), iPrevious(aOwner->iCallbackGuards) {
    aOwner->iCallbackGuards = this;
}

CVideoPlayerUtility::CBody::TCallbackGuard::~TCallbackGuard() {
    if (iOwner)
        iOwner->iCallbackGuards = iPrevious;
}

void CVideoPlayerUtility::CBody::ConstructL(RWsSession &aWsSession, RWindowBase &aWindow, const TRect &aWindowRect, const TRect &aClipRect) {
    iDispatchInstance = EVideoPlayerCreateForVersion(0, iVersion);

    User::LeaveIfNull(iDispatchInstance);

    SetOwnedWindowL(aWsSession, aWindow);
    SetDisplayRectL(aWindowRect, aClipRect);
    
    iCompleteIdle = CIdle::NewL(CActive::EPriorityHigh);
    iOpenPoll = CPeriodic::NewL(CActive::EPriorityStandard);
    CActiveScheduler::Add(this);
}

void CVideoPlayerUtility::CBody::Construct2L() {
    iDispatchInstance = EVideoPlayerCreateForVersion(0, iVersion);
    User::LeaveIfNull(iDispatchInstance);

    iCompleteIdle = CIdle::NewL(CActive::EPriorityHigh);
    iOpenPoll = CPeriodic::NewL(CActive::EPriorityStandard);
    CActiveScheduler::Add(this);
}

void CVideoPlayerUtility::CBody::SetOwnedWindowL(RWsSession &aSession, RWindowBase &aWindow) {
    if (iVersion >= 2) {
        User::Leave(KErrNotSupported);
    }
    if (iActiveWindow == &aWindow) {
        return;
    }
    TInt handle = EVideoPlayerRegisterWindow(0, iDispatchInstance, aSession.Handle(), aWindow.WsHandle());
    User::LeaveIfError(handle);
    if (iActiveWindow) {
        EVideoPlayerUnregisterWindow(0, iDispatchInstance, iActiveWindowHandle);
    }
    iActiveWindow = &aWindow;
    iActiveWindowHandle = handle;
}

void CVideoPlayerUtility::CBody::SetDisplayRectL(const TRect &aWindowRect, const TRect &aClipRect) {
    if (iVersion >= 2) {
        User::Leave(KErrNotSupported);
    }
    TVideoWindowGeometry geometry;
    geometry.iExtent = aWindowRect;
    geometry.iClip = aClipRect;
    const TPoint origin = iActiveWindow->AbsPosition();
    geometry.iExtent.Move(-origin.iX, -origin.iY);
    geometry.iClip.Move(-origin.iX, -origin.iY);
    User::LeaveIfError(EVideoPlayerSetGeometry(0, iDispatchInstance, iActiveWindowHandle, &geometry));
    iActiveClipRect = aClipRect;
}

void CVideoPlayerUtility::CBody::AddDisplayWindowL(RWsSession &aSession, RWindowBase &aWindow, const TRect &aExtent, const TRect &aClipRect) {
    if (iVersion < 2) {
        User::Leave(KErrNotSupported);
    }
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        if (iWindowInfos[i].iWindow == &aWindow) {
            User::Leave(KErrInUse);
        }
    }
    TDisplayWindowInfo info;
    info.iWindow = &aWindow;
    info.iGeometry.iExtent = aExtent;
    info.iGeometry.iClip = aClipRect;
    info.iRotation = iCurrentRotation;
    info.iScaleWidth = info.iScaleHeight = 100.0f;
    info.iHasScale = EFalse;
    info.iManagedHandle = EVideoPlayerRegisterWindow(0, iDispatchInstance, aSession.Handle(), aWindow.WsHandle());
    User::LeaveIfError(info.iManagedHandle);
    TInt error = EVideoPlayerSetGeometry(0, iDispatchInstance, info.iManagedHandle, &info.iGeometry);
    if (error == KErrNone) {
        error = iWindowInfos.Append(info);
    }
    if (error != KErrNone) {
        EVideoPlayerUnregisterWindow(0, iDispatchInstance, info.iManagedHandle);
        User::Leave(error);
    }
}

CVideoPlayerUtility::CBody::TDisplayWindowInfo &CVideoPlayerUtility::CBody::DisplayWindowL(const RWindow &aWindow) {
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        if (iWindowInfos[i].iWindow == &aWindow) {
            return iWindowInfos[i];
        }
    }
    User::Leave(KErrNotFound);
    return iWindowInfos[0];
}

void CVideoPlayerUtility::CBody::UpdateDisplayWindowL(const TDisplayWindowInfo &aInfo) {
    TVideoWindowGeometry geometry = aInfo.iGeometry;
    if (aInfo.iHasScale) {
        TSize size;
        FrameSizeL(size);
        if (!iCropRegion.IsEmpty()) {
            TRect viewport(TPoint(0, 0), size);
            viewport.Intersection(iCropRegion);
            size = viewport.Size();
        }
        if (aInfo.iRotation == EVideoRotationClockwise90 || aInfo.iRotation == EVideoRotationClockwise270) {
            size = TSize(size.iHeight, size.iWidth);
        }
        const TReal width = size.iWidth * static_cast<TReal>(aInfo.iScaleWidth) / 100.0;
        const TReal height = size.iHeight * static_cast<TReal>(aInfo.iScaleHeight) / 100.0;
        if (!(width > 0.0 && width < KMaxTInt && height > 0.0 && height < KMaxTInt)) {
            User::Leave(KErrArgument);
        }
        const TPoint center = geometry.iExtent.Center();
        const TSize scaled(static_cast<TInt>(width), static_cast<TInt>(height));
        geometry.iExtent = TRect(TPoint(center.iX - scaled.iWidth / 2, center.iY - scaled.iHeight / 2), scaled);
        geometry.iClip.Intersection(aInfo.iGeometry.iExtent);
    }
    User::LeaveIfError(EVideoPlayerSetGeometry(0, iDispatchInstance, aInfo.iManagedHandle, &geometry));
}

void CVideoPlayerUtility::CBody::SetDisplayRectForWindowL(const RWindow &aWindow, const TRect &aClipRect) {
    TDisplayWindowInfo &info = DisplayWindowL(aWindow);
    const TRect previous = info.iGeometry.iClip;
    info.iGeometry.iClip = aClipRect;
    TRAPD(error, UpdateDisplayWindowL(info));
    if (error != KErrNone) {
        info.iGeometry.iClip = previous;
        User::Leave(error);
    }
}

void CVideoPlayerUtility::CBody::SetVideoExtentL(const RWindow &aWindow, const TRect &aExtent) {
    TDisplayWindowInfo &info = DisplayWindowL(aWindow);
    const TRect previous = info.iGeometry.iExtent;
    info.iGeometry.iExtent = aExtent;
    TRAPD(error, UpdateDisplayWindowL(info));
    if (error != KErrNone) {
        info.iGeometry.iExtent = previous;
        User::Leave(error);
    }
}

void CVideoPlayerUtility::CBody::SetWindowRotationL(const RWindow &aWindow, TVideoRotation aRotation) {
    TDisplayWindowInfo &info = DisplayWindowL(aWindow);
    if (aRotation < EVideoRotationNone || aRotation > EVideoRotationClockwise270) {
        User::Leave(KErrArgument);
    }
    const TVideoRotation previous = info.iRotation;
    info.iRotation = aRotation;
    TRAPD(error, UpdateDisplayWindowL(info));
    if (error != KErrNone) {
        info.iRotation = previous;
        User::Leave(error);
    }
    User::LeaveIfError(EVideoPlayerSetWindowRotation(0, iDispatchInstance, info.iManagedHandle, aRotation));
}

TVideoRotation CVideoPlayerUtility::CBody::WindowRotationL(const RWindow &aWindow) {
    return DisplayWindowL(aWindow).iRotation;
}

void CVideoPlayerUtility::CBody::SetWindowScaleFactorL(const RWindow &aWindow, TReal32 aWidth, TReal32 aHeight) {
    TDisplayWindowInfo &info = DisplayWindowL(aWindow);
    if (!(aWidth > 0.0f && aHeight > 0.0f)) {
        User::Leave(KErrArgument);
    }
    const TDisplayWindowInfo previous = info;
    info.iScaleWidth = aWidth;
    info.iScaleHeight = aHeight;
    info.iHasScale = ETrue;
    TRAPD(error, UpdateDisplayWindowL(info));
    if (error != KErrNone) {
        info = previous;
        User::Leave(error);
    }
}

void CVideoPlayerUtility::CBody::GetWindowScaleFactorL(const RWindow &aWindow, TReal32 &aWidth, TReal32 &aHeight) {
    const TDisplayWindowInfo &info = DisplayWindowL(aWindow);
    aWidth = info.iScaleWidth;
    aHeight = info.iScaleHeight;
}

void CVideoPlayerUtility::CBody::RemoveDisplayWindow(const RWindow &aWindow) {
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        if (iWindowInfos[i].iWindow == &aWindow) {
            EVideoPlayerUnregisterWindow(0, iDispatchInstance, iWindowInfos[i].iManagedHandle);
            iWindowInfos.Remove(i);
            return;
        }
    }
}

TInt McvPlayerOpenCompleteIdleCallback(TAny *aData) {
    CVideoPlayerFeedbackHandler *util = reinterpret_cast<CVideoPlayerFeedbackHandler*>(aData);
    util->OpenComplete(KErrNone);

    return KErrNone;
}

TInt McvPlayerPrepareCompleteIdleCallback(TAny *aData) {
    CVideoPlayerFeedbackHandler *util = reinterpret_cast<CVideoPlayerFeedbackHandler*>(aData);
    util->PrepareComplete(KErrNone);

    return KErrNone;
}

void CVideoPlayerUtility::CBody::OpenFileL(const TDesC &aPath) {
    if ((iFeedbackHandler.CurrentState() == EVideoPlayerStatePlaying) || (iFeedbackHandler.CurrentState() == EVideoPlayerStatePaused)) {
        LogOut(KMcvCat, _L("Open a new video player when the video player is not stopped yet is not valid!"));
        User::Leave(KErrInUse);
        
        return;
    }

    // This also cancels an earlier asynchronous open while state is still idle.
    TCallbackGuard guard(this);
    const TUint generation = iSourceGeneration + 1;
    Close();
    if (!guard.iOwner || generation != iSourceGeneration)
        return;

    TInt result = EVideoPlayerOpenUrl(0, iDispatchInstance, &aPath);
    if (result == KRequestPending) {
        iOpenPoll->Start(1000, 50000, TCallBack(PollOpen, this));
        return;
    }
    CompleteOpen(result);
}

void CVideoPlayerUtility::CBody::CompleteOpen(TInt aResult) {
    iOpenResult = aResult;
    if (aResult == KErrNone) {
        iVideoBitRate = -1;
        iAudioBitRate = -1;
        iVideoFps = -1.0f;
    }
    iCompleteIdle->Start(TCallBack(OpenComplete, this));
}

TInt CVideoPlayerUtility::CBody::OpenComplete(TAny *aSelf) {
    CBody *self = static_cast<CBody*>(aSelf);
    self->iFeedbackHandler.OpenComplete(self->iOpenResult);
    return 0;
}

TInt CVideoPlayerUtility::CBody::PollOpen(TAny *aSelf) {
    CBody *self = static_cast<CBody*>(aSelf);
    TInt result = EVideoPlayerPollOpenUrl(0, self->iDispatchInstance);
    if (result == KRequestPending)
        return 1;
    self->iOpenPoll->Cancel();
    // Deliver from a separate idle object; Close cancels this delivery too.
    self->CompleteOpen(result);
    return 0;
}

void CVideoPlayerUtility::CBody::OpenUrlL(const TDesC &aUrl, TInt aIapId, const TDesC8 &aMimeType) {
    // URL playback uses the host connection with IAP values -1 or 0.
    if (aIapId != -1 && aIapId != 0)
        User::Leave(KErrNotSupported);
    if (aMimeType.Length() > 255 || aMimeType.Locate('\r') != KErrNotFound || aMimeType.Locate('\n') != KErrNotFound)
        User::Leave(KErrArgument);
    if (!((aUrl.Length() >= 7 && aUrl.Left(7).CompareF(_L("http://")) == 0)
        || (aUrl.Length() >= 8 && aUrl.Left(8).CompareF(_L("https://")) == 0)))
        User::Leave(KErrNotSupported);
    // MIME is a decoder hint. The actual downloaded container determines the
    // result, and is exposed through MimeType() only after a successful open.
    OpenFileL(aUrl);
}

TBool CVideoPlayerUtility::CBody::HasAudioL() const {
    TVideoMediaInfo info;
    User::LeaveIfError(EVideoPlayerMediaInfo(0, iDispatchInstance, &info));
    return info.iHasAudio;
}

TBool CVideoPlayerUtility::CBody::HasVideoL() const {
    TVideoMediaInfo info;
    User::LeaveIfError(EVideoPlayerMediaInfo(0, iDispatchInstance, &info));
    return info.iHasVideo;
}

TFourCC CVideoPlayerUtility::CBody::AudioTypeL() const {
    TVideoMediaInfo info;
    User::LeaveIfError(EVideoPlayerMediaInfo(0, iDispatchInstance, &info));
    if (!info.iAudioType)
        User::Leave(KErrNotSupported);
    return TFourCC(info.iAudioType);
}

const TDesC8 &CVideoPlayerUtility::CBody::MimeType() {
    TVideoMediaInfo info;
    iMimeType.Zero();
    if (EVideoPlayerMediaInfo(0, iDispatchInstance, &info) == KErrNone) {
        TInt length = 0;
        while (length < 64 && info.iMime[length]) ++length;
        iMimeType.Copy(TPtrC8(info.iMime, length));
    }
    return iMimeType;
}

void CVideoPlayerUtility::CBody::OpenDesL(const TDesC8 &aContent) {
    if ((iFeedbackHandler.CurrentState() == EVideoPlayerStatePlaying) || (iFeedbackHandler.CurrentState() == EVideoPlayerStatePaused)) {
        LogOut(KMcvCat, _L("Open a new video player when the video player is not stopped yet is not valid!"));
        User::Leave(KErrInUse);
        
        return;
    }

    TCallbackGuard guard(this);
    const TUint generation = iSourceGeneration + 1;
    Close();
    if (!guard.iOwner || generation != iSourceGeneration)
        return;
    CompleteOpen(EVideoPlayerOpenDes(0, iDispatchInstance, &aContent));
}

void CVideoPlayerUtility::CBody::Prepare() {
    iPrepareResult = iFeedbackHandler.CurrentState() == EVideoPlayerStateIdle ? KErrNotReady : KErrNone;
    iCompleteIdle->Start(TCallBack(PrepareComplete, this));
}

TInt CVideoPlayerUtility::CBody::PrepareComplete(TAny *aSelf) {
    CBody *self = static_cast<CBody*>(aSelf);
    self->iFeedbackHandler.PrepareComplete(self->iPrepareResult);
    return 0;
}

void CVideoPlayerUtility::CBody::Play(const TTimeIntervalMicroSeconds *aInterval) {
    const TVideoPlayerState state = iFeedbackHandler.CurrentState();
    if (state >= EVideoPlayerStatePrepared) {
        if (state == EVideoPlayerStatePlaying) {
            return;
        }

        iStatus = KRequestPending;
        iFeedbackHandler.Play();

        SetActive();

        EVideoPlayerSetPlayDoneNotification(0, iDispatchInstance, &iStatus);
        EVideoPlayerPlay(0, iDispatchInstance, aInterval);
    } else {
        LogOut(KMcvCat, _L("Requesting to play when no video has been opened to the video player yet!"));
        return;
    }
}

void CVideoPlayerUtility::CBody::Pause() {
    if (iFeedbackHandler.CurrentState() != EVideoPlayerStatePlaying) {
        if (iFeedbackHandler.CurrentState() <= EVideoPlayerStatePrepared) {
            LogOut(KMcvCat, _L("Requesting to pause when video player is not playing anything!"));
        }
        return;
    }

    Cancel();
    User::LeaveIfError(EVideoPlayerPause(0, iDispatchInstance));
    iFeedbackHandler.Pause();
}

void CVideoPlayerUtility::CBody::Stop() {
    if (iFeedbackHandler.CurrentState() <= EVideoPlayerStatePrepared) {
        return;
    }

    Cancel();
    EVideoPlayerStop(0, iDispatchInstance);
    iFeedbackHandler.Stop();
}

void CVideoPlayerUtility::CBody::Close() {
    const TUint generation = ++iSourceGeneration;
    TCallbackGuard guard(this);
    if (iOpenPoll) iOpenPoll->Cancel();
    if (iCompleteIdle) iCompleteIdle->Cancel();
    Cancel();
#ifndef MCV_EKA1
    const TSurfaceId surfaceId = iSurfaceId;
    iSurfaceId = TSurfaceId::CreateNullId();
#endif
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        EVideoPlayerUnregisterWindow(0, iDispatchInstance, iWindowInfos[i].iManagedHandle);
    }
    iWindowInfos.Reset();
    if (iDispatchInstance) EVideoPlayerClose(0, iDispatchInstance);
    iMimeType.Zero();
    iFeedbackHandler.Close();
#ifndef MCV_EKA1
    // Remove registrations before notifying. Reentrant Close/RemoveDisplay
    // cannot deliver twice, and a new Open owns a different generation.
    while (iDisplayObservers.Count()) {
        MMMFSurfaceEventHandler *handler = iDisplayObservers[0].iHandler;
        iDisplayObservers.Remove(0);
        if (!surfaceId.IsNull())
            handler->MmsehRemoveSurface(surfaceId);
        if (!guard.iOwner || generation != iSourceGeneration)
            return;
    }
#endif
}

void CVideoPlayerUtility::CBody::SetPositionL(const TTimeIntervalMicroSeconds &aWhere) {
    if (iFeedbackHandler.CurrentState() == EVideoPlayerStatePlaying) {
        LogOut(KMcvCat, _L("Attempt to set video's time position when the video is still playing!"));
        User::Leave(KErrInUse);
    }
    
    User::LeaveIfError(EVideoPlayerSetPosition(0, iDispatchInstance, &aWhere));
}

TTimeIntervalMicroSeconds CVideoPlayerUtility::CBody::PositionL() const {
    TTimeIntervalMicroSeconds position;
    User::LeaveIfError(EVideoPlayerGetPosition(0, iDispatchInstance, &position));
    
    return position;
}

void CVideoPlayerUtility::CBody::SetVolumeL(TInt aVolume) {
    User::LeaveIfError(EVideoPlayerSetVolume(0, iDispatchInstance, aVolume));
    iCurrentVolume = aVolume;
}

TInt CVideoPlayerUtility::CBody::Volume() {
    if (iCurrentVolume == -1) {
        iCurrentVolume = EVideoPlayerCurrentVolume(0, iDispatchInstance);
    }
    
    return iCurrentVolume;
}

TInt CVideoPlayerUtility::CBody::MaxVolume() const {
    return EVideoPlayerMaxVolume(0, iDispatchInstance);
}

void CVideoPlayerUtility::CBody::FrameSizeL(TSize &aSize) const {
    User::LeaveIfError(EVideoPlayerGetFrameSize(0, iDispatchInstance, &aSize));
}

void CVideoPlayerUtility::CBody::SetFpsL(const TReal32 aFps) {
    User::LeaveIfError(EVideoPlayerSetVideoFps(0, iDispatchInstance, &aFps));
    iVideoFps = aFps;
}

TReal32 CVideoPlayerUtility::CBody::Fps() {
    if (iVideoFps < 0) {
        EVideoPlayerGetVideoFps(0, iDispatchInstance, &iVideoFps);
    }
    
    return iVideoFps;
}

TTimeIntervalMicroSeconds CVideoPlayerUtility::CBody::DurationL() const {
    TTimeIntervalMicroSeconds duration;
    User::LeaveIfError(EVideoPlayerGetDuration(0, iDispatchInstance, &duration));
    
    return duration;
}

TInt CVideoPlayerUtility::CBody::VideoBitRate() {
    if (iVideoBitRate < 0) {
        iVideoBitRate = EVideoPlayerGetBitrate(0, iDispatchInstance, EFalse);
    }
    
    return iVideoBitRate;
}

TInt CVideoPlayerUtility::CBody::AudioBitRate() {
    if (iAudioBitRate < 0) {
        iAudioBitRate = EVideoPlayerGetBitrate(0, iDispatchInstance, ETrue);
    }
    
    return iAudioBitRate;
}

void CVideoPlayerUtility::CBody::SetRotationL(TVideoRotation aRotation) {
    if (aRotation < EVideoRotationNone || aRotation > EVideoRotationClockwise270) {
        User::Leave(KErrArgument);
    }
    User::LeaveIfError(EVideoPlayerSetRotation(0, iDispatchInstance, (TInt)aRotation));
    iCurrentRotation = aRotation;
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        iWindowInfos[i].iRotation = aRotation;
        UpdateDisplayWindowL(iWindowInfos[i]);
    }
}

TVideoRotation CVideoPlayerUtility::CBody::Rotation() const {
    return iCurrentRotation;
}

void CVideoPlayerUtility::CBody::RunL() {
    iFeedbackHandler.PlayComplete(iStatus.Int());
}

void CVideoPlayerUtility::CBody::DoCancel() {
    EVideoPlayerCancelPlayDoneNotification(0, iDispatchInstance);
}

CVideoPlayerUtility::CBody *CVideoPlayerUtility::CBody::NewL(MVideoPlayerUtilityObserver &aObserver, RWsSession &aWsSession, RWindowBase &aWindow, const TRect &aWindowRect, const TRect &aClipRect) {
    CVideoPlayerUtility::CBody *self = new (ELeave) CVideoPlayerUtility::CBody(aObserver, 1);

    CleanupStack::PushL(self);
    self->ConstructL(aWsSession, aWindow, aWindowRect, aClipRect);
    CleanupStack::Pop();
    
    return self;
}

CVideoPlayerUtility::CBody *CVideoPlayerUtility::CBody::New2L(MVideoPlayerUtilityObserver &aObserver) {
    CVideoPlayerUtility::CBody *self = new (ELeave) CVideoPlayerUtility::CBody(aObserver, 2);

    CleanupStack::PushL(self);
    self->Construct2L();
    CleanupStack::Pop();
    
    return self;
}

EXPORT_C CVideoPlayerUtility* CVideoPlayerUtility::NewL(MVideoPlayerUtilityObserver& aObserver,
                                          TInt aPriority,
#ifdef MCV_EKA1
                                          TMdaPriorityPreference aPref,
#else
                                          TInt aPref,
#endif
                                          RWsSession& aWs,
                                          CWsScreenDevice& aScreenDevice,
                                          RWindowBase& aWindow,
                                          const TRect& aScreenRect,
                                          const TRect& aClipRect) {
    CVideoPlayerUtility *self = new (ELeave) CVideoPlayerUtility;
    CleanupStack::PushL(self);

    self->iBody = CVideoPlayerUtility::CBody::NewL(aObserver, aWs, aWindow, aScreenRect, aClipRect);
    CleanupStack::Pop();
    
    return self;
}

#ifndef MCV_EKA1
EXPORT_C CVideoPlayerUtility2* CVideoPlayerUtility2::NewL(MVideoPlayerUtilityObserver& aObserver, TInt aPriority, TInt aPref) {
    CVideoPlayerUtility2 *self = new (ELeave) CVideoPlayerUtility2;
    CleanupStack::PushL(self);

    self->iBody = CVideoPlayerUtility::CBody::New2L(aObserver);
    CleanupStack::Pop();
    
    return self;
}

#endif

EXPORT_C void CVideoPlayerUtility::OpenFileL(const TDesC& aFileName,TUid aControllerUid) {
    if (aControllerUid != KNullUid) User::Leave(KErrNotSupported);
    iBody->OpenFileL(aFileName);
}

EXPORT_C void CVideoPlayerUtility::OpenFileL(const RFile& aFileName, TUid aControllerUid) {
    if (aControllerUid != KNullUid) User::Leave(KErrNotSupported);
#ifdef MCV_EKA1
    // EKA1 RFile cannot report its full path.
    LogOut(KMcvCat, _L("Video Player's open file through RFile is not supported on EKA1!"));
    User::Leave(KErrNotSupported);
#else
    TFileName nameFull;
    User::LeaveIfError(aFileName.FullName(nameFull));

    iBody->OpenFileL(nameFull);
#endif
}

#ifndef MCV_EKA1
EXPORT_C void CVideoPlayerUtility::OpenFileL(const TMMSource& aSource, TUid aControllerUid) {
    User::Leave(KErrNotSupported);
}

#endif

EXPORT_C void CVideoPlayerUtility::OpenDesL(const TDesC8& aDescriptor,TUid aControllerUid) {
    if (aControllerUid != KNullUid) User::Leave(KErrNotSupported);
    iBody->OpenDesL(aDescriptor);
}

EXPORT_C void CVideoPlayerUtility::OpenUrlL(const TDesC& aUrl, TInt aIapId, const TDesC8& aMimeType, TUid aControllerUid) {
    if (aControllerUid != KNullUid) User::Leave(KErrNotSupported);
    iBody->OpenUrlL(aUrl, aIapId, aMimeType);
}

EXPORT_C void CVideoPlayerUtility::Prepare() {
    iBody->Prepare();
}

EXPORT_C void CVideoPlayerUtility::Close() {
    iBody->Close();
}

EXPORT_C void CVideoPlayerUtility::Play() {
    iBody->Play(NULL);
}

EXPORT_C void CVideoPlayerUtility::Play(const TTimeIntervalMicroSeconds& aStartPoint, const TTimeIntervalMicroSeconds& aEndPoint) {
    TTimeIntervalMicroSeconds range[2];
    range[0] = aStartPoint;
    range[1] = aEndPoint;
    
    iBody->Play(range);
}

EXPORT_C TInt CVideoPlayerUtility::Stop() {
    iBody->Stop();
    return KErrNone;
}

EXPORT_C void CVideoPlayerUtility::PauseL() {
    iBody->Pause();
}

EXPORT_C void CVideoPlayerUtility::SetPriorityL(TInt aPriority,
#ifdef MCV_EKA1
    TMdaPriorityPreference aPref
#else
    TInt aPref
#endif
) {
    LogOut(KMcvCat, _L("Video Player's set priority is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::PriorityL(TInt& aPriority, TMdaPriorityPreference& aPref) const {
    LogOut(KMcvCat, _L("Video Player's get priority is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::SetDisplayWindowL(RWsSession& aWs,CWsScreenDevice& aScreenDevice,RWindowBase& aWindow,const TRect& aWindowRect,const TRect& aClipRect) {
    iBody->SetOwnedWindowL(aWs, aWindow);
    iBody->SetDisplayRectL(aWindowRect, aClipRect);
}

EXPORT_C void CVideoPlayerUtility::RegisterForVideoLoadingNotification(MVideoLoadingObserver& aCallback) {
    LogOut(KMcvCat, _L("Video Player's register video loading notification is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::GetVideoLoadingProgressL(TInt& aPercentageComplete) {
    aPercentageComplete = 100;
}

EXPORT_C void CVideoPlayerUtility::GetFrameL(TDisplayMode aDisplayMode) {
    LogOut(KMcvCat, _L("Video Player's get frame is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::GetFrameL(TDisplayMode aDisplayMode, ContentAccess::TIntent aIntent) {
    LogOut(KMcvCat, _L("Video Player's get frame with access intent is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::RefreshFrameL() {
    LogOut(KMcvCat, _L("Video Player's refresh frame is not yet implemented!"));
}

EXPORT_C TReal32 CVideoPlayerUtility::VideoFrameRateL() const {
    return iBody->Fps();
}

EXPORT_C void CVideoPlayerUtility::SetVideoFrameRateL(TReal32 aFramesPerSecond) {
    iBody->SetFpsL(aFramesPerSecond);
}

EXPORT_C void CVideoPlayerUtility::VideoFrameSizeL(TSize& aSize) const {
    iBody->FrameSizeL(aSize);
}

EXPORT_C const TDesC8& CVideoPlayerUtility::VideoFormatMimeType() const {
    return iBody->MimeType();
}

EXPORT_C TInt CVideoPlayerUtility::VideoBitRateL() const {
    return iBody->VideoBitRate();
}

EXPORT_C TInt CVideoPlayerUtility::AudioBitRateL() const {
    return iBody->AudioBitRate();
}

EXPORT_C TFourCC CVideoPlayerUtility::AudioTypeL() const {
    return iBody->AudioTypeL();
}

EXPORT_C TBool CVideoPlayerUtility::AudioEnabledL() const {
    return iBody->HasAudioL();
}

EXPORT_C void CVideoPlayerUtility::SetPositionL(const TTimeIntervalMicroSeconds& aPosition) {
    iBody->SetPositionL(aPosition);
}

EXPORT_C TTimeIntervalMicroSeconds CVideoPlayerUtility::PositionL() const {
    return iBody->PositionL();
}

EXPORT_C TTimeIntervalMicroSeconds CVideoPlayerUtility::DurationL() const {
    return iBody->DurationL();
}

EXPORT_C void CVideoPlayerUtility::SetVolumeL(TInt aVolume) {
    iBody->SetVolumeL(aVolume);
}

EXPORT_C TInt CVideoPlayerUtility::Volume() const {
    return iBody->Volume();
}

EXPORT_C TInt CVideoPlayerUtility::MaxVolume() const {
    return iBody->MaxVolume();
}

EXPORT_C void CVideoPlayerUtility::SetBalanceL(TInt aBalance) {
    if (aBalance)
        User::Leave(KErrNotSupported);
}

EXPORT_C TInt CVideoPlayerUtility::Balance()const {
    return 0; // The current decoder mixes at the centre balance only.
}

EXPORT_C void CVideoPlayerUtility::SetRotationL(TVideoRotation aRotation) {
    iBody->SetRotationL(aRotation);
}

EXPORT_C TVideoRotation CVideoPlayerUtility::RotationL() const {
    return iBody->Rotation();
}

EXPORT_C void CVideoPlayerUtility::SetScaleFactorL(TReal32 aWidthPercentage, TReal32 aHeightPercentage, TBool aAntiAliasFiltering) {
    LogOut(KMcvCat, _L("Video Player's set scale factor is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::GetScaleFactorL(TReal32& aWidthPercentage, TReal32& aHeightPercentage, TBool& aAntiAliasFiltering) const {
    LogOut(KMcvCat, _L("Video Player's get scale factor is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::SetCropRegionL(const TRect& aCropRegion) {
    iBody->SetCropRegionL(aCropRegion);
}

EXPORT_C void CVideoPlayerUtility::GetCropRegionL(TRect& aCropRegion) const {
    iBody->GetCropRegion(aCropRegion);
}

void CVideoPlayerUtility::CBody::SetCropRegionL(const TRect &aCrop) {
    User::LeaveIfError(EVideoPlayerSetCropRegion(0, iDispatchInstance, &aCrop));
    iCropRegion = aCrop;
    for (TInt i = 0; i < iWindowInfos.Count(); i++) {
        if (iWindowInfos[i].iHasScale) {
            UpdateDisplayWindowL(iWindowInfos[i]);
        }
    }
#ifndef MCV_EKA1
    if (iSurfaceId.IsNull())
        return;
    TSize size;
    FrameSizeL(size);
    TRect crop(TPoint(0, 0), size);
    if (!iCropRegion.IsEmpty()) crop.Intersection(iCropRegion);
    const TSurfaceId surfaceId = iSurfaceId;
    const TUint generation = iSourceGeneration;
    TCallbackGuard guard(this);
    TInt remaining = iDisplayObservers.Count();
    for (TInt index = 0; index < iDisplayObservers.Count() && remaining--; ) {
        const TDisplayObserver observer = iDisplayObservers[index];
        observer.iHandler->MmsehSurfaceParametersChanged(surfaceId, crop, TVideoAspectRatio(1, 1));
        if (!guard.iOwner || generation != iSourceGeneration)
            return;
        if (index < iDisplayObservers.Count() && iDisplayObservers[index].iHandler == observer.iHandler
            && iDisplayObservers[index].iDisplay == observer.iDisplay)
            ++index;
    }
#endif
}

EXPORT_C TInt CVideoPlayerUtility::NumberOfMetaDataEntriesL() const {
    LogOut(KMcvCat, _L("Video Player's number of metadata entries is not yet implemented!"));
    return 0;
}

EXPORT_C CMMFMetaDataEntry* CVideoPlayerUtility::MetaDataEntryL(TInt aIndex) const {
    LogOut(KMcvCat, _L("Video Player's get metadata entry is not yet implemented!"));
    return NULL;
}

EXPORT_C const CMMFControllerImplementationInformation& CVideoPlayerUtility::ControllerImplementationInformationL() {
    User::Leave(KErrNotSupported);
    __builtin_unreachable();
}

EXPORT_C TInt CVideoPlayerUtility::CustomCommandSync(const TMMFMessageDestinationPckg& aDestination, TInt aFunction, const TDesC8& aDataTo1, const TDesC8& aDataTo2, TDes8& aDataFrom) {
    LogOut(KMcvCat, _L("Video Player's custom command sync v1 is not yet implemented!"));
    return 0;
}

EXPORT_C TInt CVideoPlayerUtility::CustomCommandSync(const TMMFMessageDestinationPckg& aDestination, TInt aFunction, const TDesC8& aDataTo1, const TDesC8& aDataTo2) {
    LogOut(KMcvCat, _L("Video Player's custom command sync v2 is not yet implemented!"));
    return 0;
}

EXPORT_C void CVideoPlayerUtility::CustomCommandAsync(const TMMFMessageDestinationPckg& aDestination, TInt aFunction, const TDesC8& aDataTo1, const TDesC8& aDataTo2, TDes8& aDataFrom, TRequestStatus& aStatus) {
    LogOut(KMcvCat, _L("Video Player's custom command async v1 is not yet implemented!"));

    TRequestStatus *statusPtr = &aStatus;    
    User::RequestComplete(statusPtr, KErrNone);
}

EXPORT_C void CVideoPlayerUtility::CustomCommandAsync(const TMMFMessageDestinationPckg& aDestination, TInt aFunction, const TDesC8& aDataTo1, const TDesC8& aDataTo2, TRequestStatus& aStatus) {
    LogOut(KMcvCat, _L("Video Player's custom command async v2 is not yet implemented!"));

    TRequestStatus *statusPtr = &aStatus;    
    User::RequestComplete(statusPtr, KErrNone);
}

#ifndef MCV_EKA1
EXPORT_C MMMFDRMCustomCommand* CVideoPlayerUtility::GetDRMCustomCommand() {
    LogOut(KMcvCat, _L("Video Player's get drm custom command is not yet implemented!"));
    return NULL;
}

EXPORT_C void CVideoPlayerUtility::StopDirectScreenAccessL() {
    // Does nothing ;)
}

EXPORT_C void CVideoPlayerUtility::StartDirectScreenAccessL() {
    // Does nothing ;)
}

EXPORT_C TInt CVideoPlayerUtility::RegisterAudioResourceNotification(MMMFAudioResourceNotificationCallback& aCallback, TUid aNotificationEventUid, const TDesC8& aNotificationRegistrationData) {
    return KErrNotSupported; // No host audio-resource arbitration events yet.
}

EXPORT_C TInt CVideoPlayerUtility::CancelRegisterAudioResourceNotification(TUid aNotificationEventId) {
    return KErrNotSupported;
}

EXPORT_C TInt CVideoPlayerUtility::WillResumePlay() {
    return KErrNotSupported;
}

EXPORT_C TInt CVideoPlayerUtility::SetInitScreenNumber(TInt aScreenNumber) {
    LogOut(KMcvCat, _L("Video Player's set init screen number is not yet implemented!"));
    return KErrNone;
}

EXPORT_C void CVideoPlayerUtility::SetPlayVelocityL(TInt aVelocity) {
    LogOut(KMcvCat, _L("Video Player's set play velocity is not yet implemented!"));
}

EXPORT_C TInt CVideoPlayerUtility::PlayVelocityL() const {
    LogOut(KMcvCat, _L("Video Player's get play velocity is not yet implemented!"));
    return 0;
}

EXPORT_C void CVideoPlayerUtility::StepFrameL(TInt aStep) {
    LogOut(KMcvCat, _L("Video Player's Step frame is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::GetPlayRateCapabilitiesL(TVideoPlayRateCapabilities& aCapabilities) const {
    LogOut(KMcvCat, _L("Video Player's get play rate capabilities is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::SetVideoEnabledL(TBool aVideoEnabled) {
    LogOut(KMcvCat, _L("Video Player's set video enabled is not yet implemented!"));
}

EXPORT_C TBool CVideoPlayerUtility::VideoEnabledL() const {
    return iBody->HasVideoL();
}

EXPORT_C void CVideoPlayerUtility::SetAudioEnabledL(TBool aAudioEnabled) {
    LogOut(KMcvCat, _L("Video Player's set audio enabled is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::SetAutoScaleL(TAutoScaleType aScaleType) {
    LogOut(KMcvCat, _L("Video Player's set auto scale is not yet implemented!"));
}

EXPORT_C void CVideoPlayerUtility::SetAutoScaleL(TAutoScaleType aScaleType, TInt aHorizPos, TInt aVertPos) {
    LogOut(KMcvCat, _L("Video Player's set video scale is not yet implemented!"));    
}

#endif

CVideoPlayerUtility::~CVideoPlayerUtility() {
    delete iBody;
}

#ifndef MCV_EKA1
CVideoPlayerUtility2::~CVideoPlayerUtility2() {
    
}

EXPORT_C void CVideoPlayerUtility2::AddDisplayWindowL(RWsSession& aWs, CWsScreenDevice& aScreenDevice, RWindow& aWindow, const TRect& aVideoExtent, 
    const TRect& aWindowClipRect) {
    iBody->AddDisplayWindowL(aWs, aWindow, aVideoExtent, aWindowClipRect);
}

EXPORT_C void CVideoPlayerUtility2::AddDisplayWindowL(RWsSession& aWs, CWsScreenDevice& aScreenDevice, RWindow& aWindow) {
    const TRect bounds(TPoint(0, 0), aWindow.Size());
    iBody->AddDisplayWindowL(aWs, aWindow, bounds, bounds);
}

EXPORT_C void CVideoPlayerUtility2::RemoveDisplayWindow(RWindow& aWindow) {
    iBody->RemoveDisplayWindow(aWindow);
}

EXPORT_C void CVideoPlayerUtility2::SetVideoExtentL(const RWindow& aWindow, const TRect& aVideoExtent) {
    iBody->SetVideoExtentL(aWindow, aVideoExtent);
}

EXPORT_C void CVideoPlayerUtility2::SetWindowClipRectL(const RWindow& aWindow, const TRect& aWindowClipRect) {
    iBody->SetDisplayRectForWindowL(aWindow, aWindowClipRect);
}

#endif

EXPORT_C void Reserved1() {
    
}

EXPORT_C void Reserved2() {
    
}

#ifndef MCV_EKA1
EXPORT_C void CVideoPlayerUtility2::SetRotationL(const RWindow &aWindow, TVideoRotation aRotation) {
    iBody->SetWindowRotationL(aWindow, aRotation);
}

EXPORT_C TVideoRotation CVideoPlayerUtility2::RotationL(const RWindow &aWindow) {
    return iBody->WindowRotationL(aWindow);
}

EXPORT_C void CVideoPlayerUtility2::SetScaleFactorL(const RWindow &aWindow, TReal32 aWidth, TReal32 aHeight) {
    iBody->SetWindowScaleFactorL(aWindow, aWidth, aHeight);
}

EXPORT_C void CVideoPlayerUtility2::GetScaleFactorL(const RWindow &aWindow, TReal32 &aWidth, TReal32 &aHeight) {
    iBody->GetWindowScaleFactorL(aWindow, aWidth, aHeight);
}

EXPORT_C void CVideoPlayerUtility2::AddDisplayL(RWsSession &aWs, TInt aDisplay, MMMFSurfaceEventHandler &aHandler) {
    iBody->AddDisplayL(aDisplay, aHandler);
}

EXPORT_C void CVideoPlayerUtility2::RemoveDisplay(TInt aDisplay) {
    iBody->RemoveDisplay(aDisplay);
}

void CVideoPlayerUtility::CBody::AddDisplayL(TInt aDisplay, MMMFSurfaceEventHandler &aHandler) {
    TSize size;
    FrameSizeL(size);
    for (TInt i = 0; i < iDisplayObservers.Count(); i++) {
        if (iDisplayObservers[i].iDisplay == aDisplay) {
            User::Leave(KErrInUse);
        }
    }
    User::LeaveIfError(EVideoPlayerGetSurfaceId(0, iDispatchInstance, iSurfaceId.iInternal));
    TDisplayObserver observer;
    observer.iDisplay = aDisplay;
    observer.iHandler = &aHandler;
    User::LeaveIfError(iDisplayObservers.Append(observer));
    TRect crop(TPoint(0, 0), size);
    if (!iCropRegion.IsEmpty()) crop.Intersection(iCropRegion);
    const TSurfaceId surfaceId = iSurfaceId;
    aHandler.MmsehSurfaceCreated(aDisplay, surfaceId, crop, TVideoAspectRatio(1, 1));
}

void CVideoPlayerUtility::CBody::RemoveDisplay(TInt aDisplay) {
    for (TInt i = 0; i < iDisplayObservers.Count(); i++) {
        if (iDisplayObservers[i].iDisplay == aDisplay) {
            MMMFSurfaceEventHandler *handler = iDisplayObservers[i].iHandler;
            const TSurfaceId surfaceId = iSurfaceId;
            iDisplayObservers.Remove(i);
            if (!surfaceId.IsNull())
                handler->MmsehRemoveSurface(surfaceId);
            return;
        }
    }
}

#endif
