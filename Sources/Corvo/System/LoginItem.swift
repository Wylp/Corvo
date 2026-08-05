import ServiceManagement

/// Registration in System Settings → "Login Items".
///
/// Every property here is read straight from the system on each access rather
/// than cached. A cached copy is what lets a switch on screen disagree with the
/// switch that matters: the user can change this in System Settings while the
/// window is open, and an approval can be revoked by an MDM profile at any time.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but switched off for Corvo in System Settings → Login Items.
    ///
    /// This is the failure that looks like success. `register()` returns
    /// **without throwing** in this state, so a screen that only watches for a
    /// thrown error reports "on" while the system keeps Corvo shut. Corvo cannot
    /// clear it — only the user can, in System Settings — so the only honest
    /// thing to do is say so.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            return
        }
        try SMAppService.mainApp.unregister()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
