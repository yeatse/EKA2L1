import SwiftUI

struct ContentView: View {
    private let buildInfo: String = {
        guard let raw = EKA2L1StartupProbe() else { return "EKA2L1 iOS (stage 0)" }
        return String(cString: raw)
    }()

    var body: some View {
        VStack(spacing: 16) {
            Text("EKA2L1").font(.largeTitle).bold()
            Text("iOS port — stage 0 skeleton").font(.subheadline)
            Text(buildInfo).font(.footnote).foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
