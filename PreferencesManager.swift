//
//  PreferencesManager.swift
//  isee
//
//  Created by Upmanyu Jha and Updated on 6/10/2026.
//


import Foundation
import AppKit

/// Manages app preferences and state persistence
class PreferencesManager: ObservableObject {
    static let shared = PreferencesManager()
    
    private let userDefaults = UserDefaults.standard
    
    // MARK: - Keys
    private enum Keys {
        static let isMonitoringEnabled = "isMonitoringEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let autoStartMonitoring = "autoStartMonitoring"
        static let overlayPosition = "overlayPosition"
        static let showWelcomeScreen = "showWelcomeScreen"
        static let notificationsEnabled = "notificationsEnabled"
        static let overlayAutoHideDelay = "overlayAutoHideDelay"
        static let alertThreshold = "alertThreshold"
        static let autoBlurEnabled = "autoBlurEnabled"
        // Blur customization
        static let blurMaterialIndex = "blurMaterialIndex"
        static let blurOverlayColor = "blurOverlayColor"
        static let blurOverlayOpacity = "blurOverlayOpacity"
        static let blurCustomImagePath = "blurCustomImagePath"
        static let blurCustomText = "blurCustomText"
        static let blurClickToDismiss = "blurClickToDismiss"
        static let blurPreviewEnabled = "blurPreviewEnabled"
        static let blurPreviewDelay = "blurPreviewDelay"
    }
    
    // MARK: - Published Properties
    @Published var isMonitoringEnabled: Bool {
        didSet {
            userDefaults.set(isMonitoringEnabled, forKey: Keys.isMonitoringEnabled)
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            userDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        }
    }
    
    @Published var autoStartMonitoring: Bool {
        didSet {
            userDefaults.set(autoStartMonitoring, forKey: Keys.autoStartMonitoring)
        }
    }
    
    @Published var overlayPosition: CGPoint {
        didSet {
            let value = NSValue(point: overlayPosition)
            let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
            userDefaults.set(data, forKey: Keys.overlayPosition)
        }
    }
    
    @Published var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        }
    }
    
    @Published var overlayAutoHideDelay: TimeInterval {
        didSet {
            userDefaults.set(overlayAutoHideDelay, forKey: Keys.overlayAutoHideDelay)
        }
    }
    
    @Published var alertThreshold: TimeInterval {
        didSet {
            userDefaults.set(alertThreshold, forKey: Keys.alertThreshold)
        }
    }
    
    @Published var autoBlurEnabled: Bool {
        didSet {
            userDefaults.set(autoBlurEnabled, forKey: Keys.autoBlurEnabled)
        }
    }
    
    // MARK: - Blur Customization Properties
    
    /// Index into `ScreenBlurManager.BlurMaterial` (0 = toolTip darkest)
    @Published var blurMaterialIndex: Int {
        didSet {
            userDefaults.set(blurMaterialIndex, forKey: Keys.blurMaterialIndex)
        }
    }
    
    /// Overlay color (archived NSColor)
    @Published var blurOverlayColor: NSColor {
        didSet {
            let data = try? NSKeyedArchiver.archivedData(withRootObject: blurOverlayColor, requiringSecureCoding: false)
            userDefaults.set(data, forKey: Keys.blurOverlayColor)
        }
    }
    
    /// Overlay opacity 0.0 – 1.0 (default 0.65)
    @Published var blurOverlayOpacity: Double {
        didSet {
            userDefaults.set(blurOverlayOpacity, forKey: Keys.blurOverlayOpacity)
        }
    }
    
    /// Optional file path to a custom image displayed behind the colored overlay
    @Published var blurCustomImagePath: String? {
        didSet {
            userDefaults.set(blurCustomImagePath, forKey: Keys.blurCustomImagePath)
        }
    }
    
    /// Custom text shown in the bottom-right corner
    @Published var blurCustomText: String {
        didSet {
            userDefaults.set(blurCustomText, forKey: Keys.blurCustomText)
        }
    }
    
    /// When enabled, a mouse click anywhere dismisses the privacy blur
    @Published var blurClickToDismiss: Bool {
        didSet {
            userDefaults.set(blurClickToDismiss, forKey: Keys.blurClickToDismiss)
        }
    }
    
    /// When enabled, the notch camera preview shows for `blurPreviewDelay` seconds
    /// before the full-screen blur activates.
    @Published var blurPreviewEnabled: Bool {
        didSet {
            userDefaults.set(blurPreviewEnabled, forKey: Keys.blurPreviewEnabled)
        }
    }
    
    /// How long the camera preview stays visible before the blur activates (0.5 – 10 s)
    @Published var blurPreviewDelay: TimeInterval {
        didSet {
            userDefaults.set(blurPreviewDelay, forKey: Keys.blurPreviewDelay)
        }
    }
    
    /// Non-published, backwards-compatible storage
    var showWelcomeScreen: Bool {
        get {
            return userDefaults.bool(forKey: Keys.showWelcomeScreen)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.showWelcomeScreen)
        }
    }
    
    // MARK: - Initialization
    private init() {
        // Load saved preferences or use defaults
        self.isMonitoringEnabled = userDefaults.object(forKey: Keys.isMonitoringEnabled) as? Bool ?? false
        self.launchAtLogin = userDefaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.autoStartMonitoring = userDefaults.object(forKey: Keys.autoStartMonitoring) as? Bool ?? true
        self.notificationsEnabled = userDefaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.overlayAutoHideDelay = userDefaults.object(forKey: Keys.overlayAutoHideDelay) as? TimeInterval ?? 10.0
        self.alertThreshold = userDefaults.object(forKey: Keys.alertThreshold) as? TimeInterval ?? 2.0
        self.autoBlurEnabled = userDefaults.object(forKey: Keys.autoBlurEnabled) as? Bool ?? false
        
        // Load overlay position
        if let data = userDefaults.data(forKey: Keys.overlayPosition),
           let position = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: data) as? NSValue {
            self.overlayPosition = position.pointValue
        } else {
            // Default position: top-center of screen
            self.overlayPosition = CGPoint(x: 0, y: 0) // Will be set to actual screen position later
        }
        
        // Load blur customization
        self.blurMaterialIndex = userDefaults.object(forKey: Keys.blurMaterialIndex) as? Int ?? 0
        self.blurOverlayOpacity = userDefaults.object(forKey: Keys.blurOverlayOpacity) as? Double ?? 0.65
        
        if let colorData = userDefaults.data(forKey: Keys.blurOverlayColor),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            self.blurOverlayColor = color
        } else {
            self.blurOverlayColor = NSColor.black
        }
        
        self.blurCustomImagePath = userDefaults.string(forKey: Keys.blurCustomImagePath)
        self.blurCustomText = userDefaults.string(forKey: Keys.blurCustomText) ?? "🛡 iSee Privacy Active"
        self.blurClickToDismiss = userDefaults.object(forKey: Keys.blurClickToDismiss) as? Bool ?? true
        self.blurPreviewEnabled = userDefaults.object(forKey: Keys.blurPreviewEnabled) as? Bool ?? true
        self.blurPreviewDelay = userDefaults.object(forKey: Keys.blurPreviewDelay) as? TimeInterval ?? 1.5
    }
    
    // MARK: - Public Methods
    
    /// Reset all preferences to defaults
    func resetToDefaults() {
        isMonitoringEnabled = false
        launchAtLogin = false
        notificationsEnabled = true
        overlayAutoHideDelay = 10.0
        alertThreshold = 2.0
        autoBlurEnabled = false
        overlayPosition = CGPoint(x: 0, y: 0)
        showWelcomeScreen = true
        
        resetBlurCustomization()
    }
    
    /// Reset only the blur customization to factory defaults
    func resetBlurCustomization() {
        blurMaterialIndex = 0
        blurOverlayColor = NSColor.black
        blurOverlayOpacity = 0.65
        blurCustomImagePath = nil
        blurCustomText = "🛡 iSee Privacy Active"
        blurClickToDismiss = true
        blurPreviewEnabled = true
        blurPreviewDelay = 1.5
    }
    
    /// Save current overlay position
    func saveOverlayPosition(_ position: CGPoint) {
        overlayPosition = position
    }
    
    /// Get default overlay position (top-center of main screen)
    func getDefaultOverlayPosition() -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 100, y: 100)
        }
        
        let screenFrame = screen.frame
        let overlayWidth: CGFloat = 200
        let overlayHeight: CGFloat = 150
        
        // Position near the notch area (top-center)
        let x = screenFrame.midX - overlayWidth / 2
        let y = screenFrame.maxY - overlayHeight - 50 // 50 points below menu bar
        
        return CGPoint(x: x, y: y)
    }
}
