enum ClientRank {
    standard,
    premium,
}

enum SecureCapability {
    translation,
    analytics,
    businessLog,
    secureRecording,
    voipPipeline,
    wakeOnLan,
    updateRobot,
}

class AccessControl {
    const AccessControl(this.rank);

    final ClientRank rank;

    static const Set<SecureCapability> _standardCapabilities = {
        SecureCapability.translation,
        SecureCapability.analytics,
    };

    static const Set<SecureCapability> _premiumCapabilities = {
        ..._standardCapabilities,
        SecureCapability.businessLog,
        SecureCapability.secureRecording,
        SecureCapability.voipPipeline,
        SecureCapability.wakeOnLan,
        SecureCapability.updateRobot,
    };

    bool allows(SecureCapability capability) {
        return switch (rank) {
            ClientRank.standard => _standardCapabilities.contains(capability),
            ClientRank.premium => _premiumCapabilities.contains(capability),
        };
    }
}
