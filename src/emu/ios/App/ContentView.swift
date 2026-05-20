import SwiftUI

struct ContentView: View {
    private let buildInfo: String = {
        guard let raw = EKA2L1StartupProbe() else { return "EKA2L1 iOS (stage 0)" }
        return String(cString: raw)
    }()

    @State private var dyncomResult: EKA2L1CpuSmokeResult?
    @State private var dynarmicResult: EKA2L1CpuSmokeResult?
    @State private var running: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                cpuSmokeCard(title: "dyncom", result: dyncomResult)
                cpuSmokeCard(title: "Request dynarmic", result: dynarmicResult)
                Button(action: rerun) {
                    Text(running ? "Running…" : "Re-run CPU smoke")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }
            .padding()
        }
        .task { await runOnce() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EKA2L1").font(.largeTitle).bold()
            Text("iOS port — stage 1 (dyncom smoke)").font(.subheadline)
            Text(buildInfo).font(.footnote).foregroundColor(.secondary)
        }
    }

    private func cpuSmokeCard(title: String, result: EKA2L1CpuSmokeResult?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let result {
                Text("requested: \(backendName(result.requestedBackend))")
                    .font(.caption).foregroundColor(.secondary)
                Text("resolved:  \(backendName(result.resolvedBackend))")
                    .font(.caption).foregroundColor(.secondary)
                if let reason = result.fallbackReason {
                    Text("fallback:  \(reason)").font(.caption).foregroundColor(.orange)
                }
                Text(result.pass ? "PASS" : "FAIL")
                    .font(.headline)
                    .foregroundColor(result.pass ? .green : .red)
                Text("instructions executed: \(result.instructionsExecuted)")
                    .font(.caption2).foregroundColor(.secondary)
                registerGrid(result: result)
                if let diff = result.diff {
                    Text(diff).font(.caption2.monospaced()).foregroundColor(.red)
                }
            } else {
                Text("not yet run").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    private func registerGrid(result: EKA2L1CpuSmokeResult) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0 ..< result.registers.count, id: \.self) { i in
                Text(String(format: "r%02d = 0x%08X", i, result.registers[i].uint32Value))
                    .font(.caption2.monospaced())
            }
            Text(String(format: "pc  = 0x%08X", result.pc)).font(.caption2.monospaced())
            Text(String(format: "lr  = 0x%08X", result.lr)).font(.caption2.monospaced())
            Text(String(format: "sp  = 0x%08X", result.sp)).font(.caption2.monospaced())
            Text(String(format: "cpsr= 0x%08X", result.cpsr)).font(.caption2.monospaced())
        }
    }

    private func backendName(_ backend: EKA2L1SmokeBackend) -> String {
        switch backend {
        case .dynarmic: return "dynarmic"
        case .dyncom:   return "dyncom"
        @unknown default: return "?"
        }
    }

    private func rerun() {
        Task { await runOnce() }
    }

    @MainActor
    private func runOnce() async {
        guard !running else { return }
        running = true
        defer { running = false }
        // Each invocation runs on a background queue so we never block the
        // SwiftUI main thread; dyncom is fast but the principle holds for
        // larger blobs in later stages.
        let d = await Self.run(backend: .dyncom)
        let j = await Self.run(backend: .dynarmic)
        self.dyncomResult = d
        self.dynarmicResult = j
    }

    private static func run(backend: EKA2L1SmokeBackend) async -> EKA2L1CpuSmokeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = EKA2L1CpuSmokeBridge.run(with: backend)
                continuation.resume(returning: result)
            }
        }
    }
}

#Preview {
    ContentView()
}
