// A translucent red window must retain the blue window behind it.
#include <e32std.h>
#include <w32std.h>
int main() {
    RWsSession ws;
    if (ws.Connect() != KErrNone) return 1;
    CWsScreenDevice screen(ws);
    if (screen.Construct() != KErrNone) return 2;
    CWindowGc gc(&screen);
    if (gc.Construct() != KErrNone) return 3;
    RWindowGroup group(ws);
    if (group.Construct(1) != KErrNone) return 4;
    group.SetOrdinalPosition(0);
    RWindow base(ws), alpha(ws);
    if (base.Construct(group, 2) != KErrNone || alpha.Construct(group, 3) != KErrNone) return 5;
    base.SetExtent(TPoint(0, 0), TSize(200, 200));
    base.SetBackgroundColor(TRgb(0, 0, 255));
    base.Activate();
    gc.Activate(base);
    base.BeginRedraw();
    gc.SetPenStyle(CGraphicsContext::ENullPen);
    gc.SetBrushStyle(CGraphicsContext::ESolidBrush);
    gc.SetBrushColor(TRgb(0, 0, 255));
    gc.DrawRect(TRect(0, 0, 200, 200));
    base.EndRedraw();
    gc.Deactivate();
    alpha.SetExtent(TPoint(0, 0), TSize(100, 100));
    if (alpha.SetTransparencyAlphaChannel() != KErrNone) return 6;
    alpha.SetBackgroundColor(TRgb(0, 0, 0, 0));
    alpha.Activate();
    gc.Activate(alpha);
    alpha.BeginRedraw();
    gc.SetPenStyle(CGraphicsContext::ENullPen);
    gc.SetBrushStyle(CGraphicsContext::ESolidBrush);
    gc.SetBrushColor(TRgb(255, 0, 0, 128));
    gc.DrawRect(TRect(0, 0, 100, 100));
    alpha.EndRedraw();
    gc.Deactivate();
    ws.Finish();
    User::After(30000000);
    alpha.Close(); base.Close(); group.Close(); ws.Close();
    return 0;
}
