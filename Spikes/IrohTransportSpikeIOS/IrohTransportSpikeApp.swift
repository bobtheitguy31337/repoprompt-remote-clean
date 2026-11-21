import SwiftUI

@main
struct IrohTransportSpikeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = IrohSpikeModel()

    var body: some Scene {
        WindowGroup {
            IrohSpikeContentView(model: model)
                .task {
                    await model.runSimulatorGateIfRequested()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await model.stop() }
            }
        }
    }
}
