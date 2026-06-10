//
//  ScreenBlurManager.swift
//  isee
//
//  Created by Upmanyu Jha and Updated on 6/10/2026.
//
//  Manages a full-screen privacy blur overlay across all displays
//  when a shoulder surfer is detected. Uses native NSVisualEffectView
//  with a customizable colored overlay to obscure screen content
//  while still allowing the user to see their workspace (blurred).
//
//  Customization (read from PreferencesManager):
//   - Blur material (toolTip, menu, HUD, popover, sidebar)
//   - Overlay color + opacity
//   - Custom image backdrop
//   - Custom text indicator
//
//  Design:
//  - Blur windows are created once and kept alive (never closed); we
//    just order them in/out. This avoids dealloc crashes from rapid
//    show/hide cycles.
//  - All NSWindow operations are forced onto the main thread.
//  - A guard flag prevents re-entrant calls from the Escape-key event
//    monitor.
//  - Call applyCustomization() to rebuild windows with new preferences.

import AppKit
import SwiftUI
import Carbon

// MARK: - Blur Material Options

extension ScreenBlurManager {
    /// Available `NSVisualEffectView.Material` options for the privacy blur.
    /// All values are non-deprecated and available on macOS 13.0+.
    enum BlurMaterial: Int, CaseIterable, Identifiable {
        case toolTip = 0
        case menu = 1
        case hudWindow = 2
        case popover = 3
        case sidebar = 4
        
        var id: Int { rawValue }
        
        /// Human-readable label for settings UI
        var displayName: String {
            switch self {
            case .toolTip:   return "Tool Tip (Darkest)"
            case .menu:      return "Menu"
            case .hudWindow: return "HUD Window"
            case .popover:   return "Popover"
            case .sidebar:   return "Sidebar"
            }
        }
        
        /// The underlying `NSVisualEffectView.Material`
        var material: NSVisualEffectView.Material {
            switch self {
            case .toolTip:   return .toolTip
            case .menu:      return .menu
            case .hudWindow: return .hudWindow
            case .popover:   return .popover
            case .sidebar:   return .sidebar
            }
        }
    }
}

// MARK: - ScreenBlurManager

/// Manages full-screen blur overlay windows for privacy protection.
/// All public methods are thread-safe and dispatch to the main thread.
class ScreenBlurManager: ObservableObject {
    static let shared = ScreenBlurManager()
    
    @Published var isBlurring = false
    
    /// Windows are created once and reused — no close/recreate cycle.
    private var blurWindows: [NSWindow] = []
    private var windowsPrepared = false
    /// Prevents re-entrant hideBlur calls (e.g. from Carbon callback while state also changes)
    private var isHiding = false
    
    /// Cached custom image to avoid re-reading from disk on multi-screen builds
    private var cachedCustomImage: NSImage?
    private var cachedImagePath: String?
    
    /// Carbon hotkey reference for Escape key dismissal
    private var escapeHotKeyRef: EventHotKeyRef?
    private static var escapeHandlerInstalled = false
    
    /// Global mouse-down monitor for click-to-dismiss
    private var clickDismissMonitor: Any?
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Install the Carbon event handler once for the lifetime of the app
        Self.installEscapeHandler()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        removeEscapeHotKey()
    }
    
    // MARK: - Public API (all dispatch to main thread)
    
    /// Show the privacy blur overlay on all screens
    func showBlur() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showBlur() }
            return
        }
        guard !isBlurring else { return }
        
        if !windowsPrepared {
            buildWindows()
        }
        
        // Update frames — match windows to screens by ID (not index, which can
        // break when displays are rearranged or the screen-order array changes).
        let screenMap: [String: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.map { ($0.screenID, $0) }
        )
        for window in blurWindows {
            if let windowID = window.screen?.screenID, let screen = screenMap[windowID] {
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
            } else {
                // Window's screen is gone — place on the first available screen
                if let firstScreen = NSScreen.screens.first {
                    window.setFrame(firstScreen.frame, display: true)
                }
            }
            window.orderFrontRegardless()
        }
        
        isBlurring = true
        setupEscapeHotKey()
        setupClickDismissIfNeeded()
        print("ScreenBlurManager: Privacy blur activated on \(NSScreen.screens.count) screen(s)")
    }
    
    /// Hide the privacy blur overlay
    func hideBlur() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.hideBlur() }
            return
        }
        guard isBlurring, !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        
        removeEscapeHotKey()
        removeClickDismissMonitor()
        
        for window in blurWindows {
            window.orderOut(nil)
        }
        // Do NOT close or remove windows — keep them alive for fast re-show
        
        isBlurring = false
        print("ScreenBlurManager: Privacy blur deactivated")
    }
    
    /// Toggle the privacy blur overlay
    func toggleBlur() {
        if isBlurring {
            hideBlur()
        } else {
            showBlur()
        }
    }
    
    /// Rebuild all windows with current customization preferences.
    /// Safe to call whether blur is active or not.
    func applyCustomization() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyCustomization() }
            return
        }
        // Invalidate image cache so the next build picks up changes
        cachedCustomImage = nil
        cachedImagePath = nil
        
        // Refresh click-to-dismiss monitor in case preference changed
        if isBlurring {
            removeClickDismissMonitor()
            setupClickDismissIfNeeded()
        }
        
        rebuildWindows()
    }
    
    // MARK: - Private
    
    /// Force a rebuild of all windows (call after screen/customization changes)
    private func rebuildWindows() {
        let wasBlurring = isBlurring
        if wasBlurring {
            removeEscapeHotKey()
            removeClickDismissMonitor()
            for window in blurWindows {
                window.orderOut(nil)
            }
        }
        blurWindows.removeAll()
        windowsPrepared = false
        isBlurring = false
        
        if wasBlurring {
            buildWindows()
            for window in blurWindows {
                window.orderFrontRegardless()
            }
            isBlurring = true
            setupEscapeHotKey()
            setupClickDismissIfNeeded()
        }
    }
    
    /// Respond to screen layout changes (display connected/disconnected/resized).
    /// Rebuilds all blur windows when the screen configuration changes so each
    /// window stays aligned with its display.
    @objc private func screenConfigurationChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.screenConfigurationChanged() }
            return
        }
        guard isBlurring || windowsPrepared else { return }
        rebuildWindows()
    }
    
    /// Create a blur window for each active display.
    /// Called once during `showBlur()` if windows haven't been prepared yet,
    /// and on screen-configuration changes.
    private func buildWindows() {
        blurWindows = NSScreen.screens.map { createBlurWindow(for: $0) }
        windowsPrepared = true
    }
    
    /// Build the content view for a single screen, reading current preferences.
    private func createBlurWindow(for screen: NSScreen) -> NSWindow {
        let prefs = PreferencesManager.shared
        let frame = screen.frame
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,       // Defer creation — reduces launch-time cost
            screen: screen
        )
        
        // Place above everything except screensavers and critical system UI
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true  // User can still interact with apps underneath
        window.hasShadow = false
        window.collectionBehavior = [
            .canJoinAllSpaces,      // Appears on every Space
            .fullScreenAuxiliary,   // Works with full-screen apps
            .stationary,            // Doesn't move during transitions
            .ignoresCycle,          // Not in window cycle (Cmd+`)
            .transient              // Not shown in Mission Control
        ]
        window.acceptsMouseMovedEvents = false
        
        // ── Layer 1: Native blur using NSVisualEffectView ──
        let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blurView.autoresizingMask = [.width, .height]
        let material = BlurMaterial(rawValue: prefs.blurMaterialIndex)?.material ?? .toolTip
        blurView.material = material
        blurView.blendingMode = .behindWindow  // Blurs what's behind this window
        blurView.state = .active
        
        // ── Layer 2: Optional custom image (behind the color overlay) ──
        let imageView: NSImageView?
        if let customImage = loadCustomImage() {
            let imgView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
            imgView.image = customImage
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.autoresizingMask = [.width, .height]
            imageView = imgView
        } else {
            imageView = nil
        }
        
        // ── Layer 3: Colored overlay — tints the image OR provides a solid backdrop ──
        let overlayColor = prefs.blurOverlayColor
        let overlayOpacity = CGFloat(prefs.blurOverlayOpacity)
        let overlayView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = overlayColor.withAlphaComponent(overlayOpacity).cgColor
        
        // ── Privacy indicator (bottom-right corner) ──
        let indicatorText = prefs.blurCustomText.isEmpty ? "🛡 iSee Privacy Active" : prefs.blurCustomText
        let indicator = NSTextField(labelWithString: indicatorText)
        indicator.sizeToFit()
        let indicatorWidth = max(indicator.frame.width + 8, 120)
        indicator.frame = NSRect(
            x: frame.width - indicatorWidth - 16,
            y: 16,
            width: indicatorWidth,
            height: 20
        )
        indicator.textColor = NSColor.white.withAlphaComponent(0.35)
        indicator.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        indicator.backgroundColor = .clear
        indicator.isBezeled = false
        indicator.isEditable = false
        indicator.autoresizingMask = [.minXMargin, .minYMargin]
        
        // ── Assemble (order matters: bottom → top) ──
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.addSubview(blurView)
        if let imgView = imageView {
            contentView.addSubview(imgView)
        }
        contentView.addSubview(overlayView)
        contentView.addSubview(indicator)
        
        window.contentView = contentView
        
        return window
    }
    
    /// Load the custom image from disk, caching between calls for multi-screen builds.
    private func loadCustomImage() -> NSImage? {
        let prefs = PreferencesManager.shared
        guard let path = prefs.blurCustomImagePath, !path.isEmpty else {
            cachedCustomImage = nil
            cachedImagePath = nil
            return nil
        }
        
        // Use cache if path hasn't changed
        if path == cachedImagePath, let cached = cachedCustomImage {
            return cached
        }
        
        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url) else {
            print("ScreenBlurManager: Could not load custom image at \(path)")
            cachedCustomImage = nil
            cachedImagePath = nil
            return nil
        }
        
        cachedCustomImage = image
        cachedImagePath = path
        return image
    }
    
    // MARK: - Carbon HotKey (Escape to dismiss)
    
    /// Register Escape (kVK_Escape = 53) as a global hot key.
    /// Works even when iSee is not the active app — no accessibility permissions needed.
    private func setupEscapeHotKey() {
        guard escapeHotKeyRef == nil else { return }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x49534545), id: 1) // 'ISEE'
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),       // key code = Escape
            UInt32(0),                // no modifier keys
            hotKeyID,
            GetEventDispatcherTarget(),
            0,                        // 0 = non-exclusive (Escape still reaches active app)
            &hotKeyRef
        )
        
        if status == noErr {
            escapeHotKeyRef = hotKeyRef
        } else {
            print("ScreenBlurManager: RegisterEventHotKey failed (error \(status))")
        }
    }
    
    /// Unregister the Escape hot key.
    private func removeEscapeHotKey() {
        guard let ref = escapeHotKeyRef else { return }
        UnregisterEventHotKey(ref)
        escapeHotKeyRef = nil
    }
    
    /// Install a Carbon event handler for hot key presses.
    /// Called once in init() — handles all registered hot keys.
    private static func installEscapeHandler() {
        guard !escapeHandlerInstalled else { return }
        
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            escapeHotKeyProc,
            1,
            &eventType,
            nil,
            nil
        )
        
        if status == noErr {
            escapeHandlerInstalled = true
        } else {
            print("ScreenBlurManager: InstallEventHandler failed (error \(status))")
        }
    }
    
    // MARK: - Click-to-Dismiss (global mouse monitor)
    
    /// Set up a global mouse-down monitor if the user preference is enabled.
    /// Every mouse click dismisses the privacy blur. The click still passes
    /// through to the active app (global monitors cannot swallow events).
    private func setupClickDismissIfNeeded() {
        guard clickDismissMonitor == nil else { return }
        guard PreferencesManager.shared.blurClickToDismiss else { return }
        
        clickDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Global monitor fires on a background thread; dispatch to main
            DispatchQueue.main.async {
                self?.hideBlur()
            }
        }
    }
    
    /// Remove the global mouse-down monitor.
    private func removeClickDismissMonitor() {
        if let monitor = clickDismissMonitor {
            NSEvent.removeMonitor(monitor)
            clickDismissMonitor = nil
        }
    }
}

// MARK: - Carbon HotKey C Callback

/// C-callable function pointer that the Carbon event dispatcher calls
/// when any registered hot key is pressed.
private let escapeHotKeyProc: EventHandlerProcPtr = { (_, event, _) -> OSStatus in
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    
    guard err == noErr, hotKeyID.signature == OSType(0x49534545) else {
        return OSStatus(eventNotHandledErr)
    }
    
    DispatchQueue.main.async {
        ScreenBlurManager.shared.hideBlur()
    }
    return noErr
}

// MARK: - Screen identity helper

private extension NSScreen {
    /// A stable unique identifier for a screen.
    /// Uses the hardware NSScreenNumber when available, falling back to
    /// frame origin + size — this avoids the "unknown" collision that
    /// can occur with virtual displays, Sidecar, or AirPlay.
    var screenID: String {
        if let number = self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] {
            return "\(number)"
        }
        return "\(self.frame.origin.x),\(self.frame.origin.y),\(self.frame.size.width),\(self.frame.size.height)"
    }
}
