struct FirstRunStarterModel: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let model: DownloadableModel
    let badge: String?

    static func recommended() -> [FirstRunStarterModel] {
        let profiles = ModelCapabilityProfile.visibleProfiles()
        return [
            bestChatForThisMac(),
            item(for: .image, title: "Image", detail: "Generate images locally", icon: "photo", profiles: profiles),
            item(for: .audio, title: "Speech", detail: "Create spoken audio", icon: "waveform", profiles: profiles),
            item(for: .music, title: "Music", detail: "Generate music tracks", icon: "music.note", profiles: profiles)
        ]
        .compactMap { $0 }
    }

    static func bestChatForThisMac(
        hardwareMemoryGB: Double = SystemHardware.currentMemoryGB
    ) -> FirstRunStarterModel? {
        guard let profile = ModelCapabilityProfile.bestProfile(
            for: .vision,
            hardwareMemoryGB: hardwareMemoryGB
        ) else {
            return nil
        }

        return FirstRunStarterModel(
            id: profile.modelId,
            title: "Chat",
            detail: "Best fit for local Chat on this Mac",
            icon: "bubble.left.and.bubble.right",
            model: profile.downloadableModel,
            badge: "Best for this Mac"
        )
    }

    private static func item(
        for modality: ModelModality,
        title: String,
        detail: String,
        icon: String,
        profiles: [ModelCapabilityProfile]
    ) -> FirstRunStarterModel? {
        guard let profile = profiles
            .filter({ $0.modality == modality })
            .sorted(by: isStarterSortedBefore)
            .first else {
            return nil
        }

        return FirstRunStarterModel(
            id: profile.modelId,
            title: title,
            detail: detail,
            icon: icon,
            model: profile.downloadableModel,
            badge: nil
        )
    }

    private static func isStarterSortedBefore(
        _ lhs: ModelCapabilityProfile,
        _ rhs: ModelCapabilityProfile
    ) -> Bool {
        let lhsFit = lhs.fit()
        let rhsFit = rhs.fit()
        if lhsFit.sortRank != rhsFit.sortRank {
            return lhsFit.sortRank < rhsFit.sortRank
        }

        return lhs.totalDownloadSizeGB < rhs.totalDownloadSizeGB
    }
}
