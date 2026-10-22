import SwiftUI
import VoiceCore

/// "Automatic" or a forced tier.
enum TierChoice: Hashable {
    case automatic
    case forced(HardwareTier)

    var tier: HardwareTier? {
        if case .forced(let tier) = self { return tier }
        return nil
    }
}

/// The tier's pop-up menu, the same on the first-launch screen and in Settings › Advanced: "Automatic: <the tier this
/// Mac gets on its own>", then each tier the user can choose, with its language model.
struct TierMenu: View {
    /// The tier the user forced; nil for "Automatic".
    let override: HardwareTier?
    /// The tier this Mac gets on its own; nil until the engine has said.
    let recommended: HardwareTier?
    /// Another item was picked.
    let choose: (TierChoice) -> Void

    var body: some View {
        PopUpMenu(title: override.map { Text(StateText.tier($0)) } ?? automaticLabel, label: Text("Tier")) {
            Picker(selection: Binding(
                get: { override.map(TierChoice.forced) ?? .automatic },
                set: { choice in
                    if choice.tier != override { choose(choice) }
                }))
            {
                automaticLabel.tag(TierChoice.automatic)
                ForEach(HardwareTier.selectable, id: \.self) { tier in
                    label(tier).tag(TierChoice.forced(tier))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var automaticLabel: Text {
        guard let recommended else { return Text("Automatic") }
        return Text("Automatic: \(Text(StateText.tier(recommended)))")
    }

    /// The tier, its language model, and whether it could be tested.
    private func label(_ tier: HardwareTier) -> Text {
        let name = ModelCatalog.languageModel(for: tier)?.displayName ?? ""
        return Text(StateText.tier(tier)) + Text(verbatim: " · \(name)")
            + (tier.isTested ? Text(verbatim: "") : Text(" · untested"))
    }
}
