# Alpha window regression probe

Build/package with symbian-platform 0.3.0 like the neighboring invalid_gc probe.
Launch on a ScreenPlay device (e.g. X7) and capture a guest screenshot within 30s.
At (50,50) expect approximately RGB (128,0,127); at (150,150) expect (0,0,255).
The alpha window must blend with the blue window, including a server recomposite.
This follows `RWindow::SetTransparencyAlphaChannel` and `SetBackgroundColor` in
SymbianSource/oss.FCL.sf.os.graphics/windowing/windowserver/nga/CLIENT/RWINDOW.CPP.
