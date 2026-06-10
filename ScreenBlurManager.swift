//
//  ScreenBlurManager.swift
//  isee
//
//  Created by Upmanyu Jha and Updated on 6/10/2026.
//
//  Manages a full-screen privacy blur overlay across all displays
//  when a shoulder surfer is detected. Uses native NSVisualEffectView
//  with a dark overlay to obscure screen content while still allowing
//  the user to see their workspace (blurred).
//
//  Design:
//  - Blur windows are created once and kept alive (never closed); we
//    just order them in/out. This avoids dealloc crashes from rapid
//    show/hide cycles.
//  - All NSWindow operations are forced onto the main thread.
//  - A guard flag prevents re-entrant calls from the Escape-key event
//    monitor.

import AppKit
import SwiftUI

/// Manages full-screen blur overlay windows for privacy protection.
/// All public methods are thread-safe and dispatch to the main thread.
class ScreenBlurManager: ObservableObject {
    static let shared = ScreenBlurManager()
    
    @Published var isBlurring = false
    
    /// Windows are created once and reused — no close/recreate cycle.
    private var blurWindows: [NSWindow] = []
    private var windowsPrepared = false
    private var eventMonitor: Any?
    /// Prevents re-entrant hideBlur calls (e.g. from event monitor while state also changes)
    private var isHiding = false
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
        
        // Update frame in case screen layout changed while we were hidden
        for (index, window) in blurWindows.enumerated() {
            if index < NSScreen.screens.count {
                let screen = NSScreen.screens[index]
                if window.screen?.screenID != screen.screenID {
                    window.setFrame(screen.frame, display: true)
                }
            }
            window.orderFrontRegardless()
        }
        
        isBlurring = true
        setupEventMonitor()
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
        
        removeEventMonitor()
        
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
    
    /// Force a rebuild of all windows (call after screen count changes)
    private func rebuildWindows() {
        let wasBlurring = isBlurring
        if wasBlurring {
            removeEventMonitor()
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
            setupEventMonitor()
        }
    }
    
    // MARK: - Private
    
    @objc private func screenConfigurationChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.screenConfigurationChanged() }
            return
        }
        guard isBlurring || windowsPrepared else { return }
        rebuildWindows()
    }
    
    private func buildWindows() {
        blurWindows = NSScreen.screens.map { createBlurWindow(for: $0) }
        windowsPrepared = true
    }
    
    private func createBlurWindow(for screen: NSScreen) -> NSWindow {
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
        if #available(macOS 10.14, *) {
            blurView.material = .toolTip  // Dark, modern blur (not deprecated)
        } else {
            blurView.material = .dark
        }
        blurView.blendingMode = .behindWindow  // Blurs what's behind this window
        blurView.state = .active
        
        // ── Layer 2: Dark overlay for maximum obscuring ──
        let darkOverlay = NSView(frame: NSRect(origin: .zero, size: frame.size))
        darkOverlay.autoresizingMask = [.width, .height]
        darkOverlay.wantsLayer = true
        // 65% black on top of the blur — text is unreadable,
        // but the user can still perceive layout/brightness
        darkOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        
        // ── Privacy indicator (bottom-right corner) ──
        let indicator = NSTextField(labelWithString: "🛡 iSee Privacy Active")
        let indicatorWidth: CGFloat = 180
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
        
        // ── Assemble ──
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.addSubview(blurView)
        contentView.addSubview(darkOverlay)
        contentView.addSubview(indicator)
        
        window.contentView = contentView
        
        return window
    }
    
    /// Set up a local event monitor so the user can press Escape to dismiss the blur
    private func setupEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // 53 = Escape key
                self?.hideBlur()
                return nil // Swallow the event
            }
            return event
        }
    }
    
    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Screen identity helper

private extension NSScreen {
    /// A simple unique identifier for a screen based on its device description.
    var screenID: String {
        "\(self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown")"
    }
}
