import VoiceCore

// A connected tool's disc, the same on the Mac (its settings' lists, the conversation's card) and on the iPhone and iPad
// (the conversation's card), which get it with the card (`ConnectedToolAction.disc`).

extension ConnectedToolDisc {
    /// Home Assistant's house on turquoise; otherwise a plug (a service on the home network) or a globe (on the
    /// internet), on a colour that follows the tool's place in the settings' list.
    var look: (icon: Icon, color: RGBA) {
        let colors = [Palette.azureSoft, Palette.sunSoft, Palette.coralSoft]
        let color = colors[(index % colors.count + colors.count) % colors.count]
        switch kind {
        case .homeAssistant: return (.home, Palette.turquoiseSoft)
        case .homeNetwork: return (.plug, color)
        case .internet: return (.globe, color)
        }
    }
}
