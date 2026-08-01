import SwiftUI

public struct AfrezzaQuickActionsView: View {
    @ObservedObject private var prefs: AfrezzaPreferences

    // Recommended dose from the app; used to pick nearest cartridge on AF tap
    private let recommendedDose: Double

    // Callback when a specific cartridge size is chosen
    public var onSelectCartridge: (Int) -> Void

    // Optional callback for AF quick action
    public var onAFQuickAction: ((Int) -> Void)?

    public init(
        prefs: AfrezzaPreferences = AfrezzaPreferences(),
        recommendedDose: Double,
        onSelectCartridge: @escaping (Int) -> Void,
        onAFQuickAction: ((Int) -> Void)? = nil
    ) {
        self.prefs = prefs
        self.recommendedDose = recommendedDose
        self.onSelectCartridge = onSelectCartridge
        self.onAFQuickAction = onAFQuickAction
    }

    @State private var selected: Int?

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prefs.enabled {
                Text("Afrezza").font(.headline)
                HStack(spacing: 8) {
                    ForEach(prefs.cartridgeSizes.sorted(), id: \.self) { size in
                        Button(action: {
                            selected = size
                            prefs.lastUsedSize = size
                            impact(.medium)
                            onSelectCartridge(size)
                        }) {
                            Text("\(size)U")
                                .font(.body.weight(.semibold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(
                                    Capsule()
                                        .fill(selected == size ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                                )
                        }
                        .accessibilityLabel("Afrezza \(size) units")
                    }

                    Button(action: {
                        let nearest = prefs.nearestCartridge(for: recommendedDose)
                        selected = nearest
                        prefs.lastUsedSize = nearest
                        impact(.rigid)
                        onSelectCartridge(nearest)
                        onAFQuickAction?(nearest)
                    }) {
                        Label("AF", systemImage: "capsule.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.body.weight(.semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .accessibilityLabel("Afrezza quick action")
                }
            }
        }
    }

    private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if os(iOS)
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

#Preview {
    AfrezzaQuickActionsView(recommendedDose: 7.6, onSelectCartridge: { _ in })
        .padding()
}
