// Expected result on Symbian: client panic WSERV 6; the server stays alive.
#include <e32std.h>
#include <w32std.h>
int main() {
    RWsSession ws;
    if (ws.Connect() != KErrNone) return 1;
    CWsScreenDevice screen(ws);
    if (screen.Construct() != KErrNone) return 2;
    CWindowGc gc(&screen);
    if (gc.Construct() != KErrNone) return 3;
    RWindow invalid(ws);
    gc.Activate(invalid);
    ws.Finish();
    return 99;
}
