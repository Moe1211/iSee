//
//  SettingsView.swift
//  isee
//
//  Created by Upmanyu Jha and Updated on 6/10/2026.
//


import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var preferencesManager = PreferencesManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var backgroundService = BackgroundMonitoringService.shared
    
    /// Bridged binding for the ColorPicker (SwiftUI Color → NSColor)
    private var overlayColorBinding: Binding<Color> {
        Binding(
            get: { Color(preferencesManager.blurOverlayColor) },
            set: { newColor in
                if let cgColor = newColor.cgColor {
                    preferencesManager.blurOverlayColor = NSColor(cgColor: cgColor) ?? .black
                }
            }
        )
    }
    
    /// For the "Browse…" NSOpenPanel action
    @State private var showImagePicker = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("iSee Settings")
                .font(.title)
                .fontWeight(.bold)
            
            ScrollView {
                Form {
                    Section("In-App Notifications") {
                        Toggle("Enable In-Notch Notifications", isOn: $preferencesManager.notificationsEnabled)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications appear directly in the Mac notch area (Dynamic Island style).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Note: These are in-app notifications and won't appear in macOS Settings → Notifications. You can also toggle this using the bell icon in the camera island.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        .padding(.vertical, 2)
                        
                        HStack {
                            Text("Auto-hide Delay")
                            Spacer()
                            Text("\(Int(preferencesManager.overlayAutoHideDelay)) seconds")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $preferencesManager.overlayAutoHideDelay, in: 5...30, step: 5)
                            .help("How long notification popups stay visible before auto-dismissing")
                    }
                    
                    Section("Monitoring") {
                        Toggle("Auto-start Monitoring", isOn: $preferencesManager.autoStartMonitoring)
                        
                        Toggle("Launch at Login", isOn: $preferencesManager.launchAtLogin)
                    }
                    
                    Section("Detection") {
                        HStack {
                            Text("Alert Cooldown Period")
                            Spacer()
                            Text("\(Int(preferencesManager.alertThreshold)) seconds")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $preferencesManager.alertThreshold, in: 1...10, step: 1)
                    }
                    
                    Section("Privacy") {
                        Toggle("Auto-blur Screen on Detection", isOn: $preferencesManager.autoBlurEnabled)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("When enabled, iSee will apply a full-screen blur overlay across all displays when a shoulder surfer is detected. The blur auto-dismisses when the threat passes.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Press Escape to dismiss the blur manually. All processing is on-device.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        .padding(.vertical, 2)
                    }
                    
                    // ── Blur Customization Section ──
                    Section("Blur Customization") {
                        // Blur material picker
                        Picker("Blur Material", selection: $preferencesManager.blurMaterialIndex) {
                            ForEach(ScreenBlurManager.BlurMaterial.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        
                        // Overlay color
                        HStack {
                            ColorPicker("Overlay Color", selection: overlayColorBinding)
                            Spacer()
                        }
                        
                        // Overlay opacity
                        HStack {
                            Text("Overlay Opacity")
                            Spacer()
                            Text("\(Int(preferencesManager.blurOverlayOpacity * 100))%")
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        Slider(value: $preferencesManager.blurOverlayOpacity, in: 0...1, step: 0.05)
                            .help("Opacity of the colored overlay on top of the blur. Higher values obscure more.")
                        
                        // Custom image
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Custom Image:")
                                    .foregroundColor(.primary)
                                Spacer()
                                
                                if let path = preferencesManager.blurCustomImagePath, !path.isEmpty {
                                    Text(shortPath(path))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 120)
                                } else {
                                    Text("None")
                                        .foregroundColor(.secondary)
                                }
                                
                                Button("Browse…") {
                                    browseForImage()
                                }
                                .fixedSize()
                                
                                if preferencesManager.blurCustomImagePath != nil {
                                    Button("Clear") {
                                        preferencesManager.blurCustomImagePath = nil
                                    }
                                    .foregroundColor(.red)
                                    .fixedSize()
                                }
                            }
                            
                            Text("The image is shown behind the colored overlay. Recommended: a dark wallpaper or solid-color image.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // Custom text
                        HStack {
                            Text("Custom Message")
                            Spacer()
                            TextField("🛡 iSee Privacy Active", text: $preferencesManager.blurCustomText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        
                        // Click to dismiss
                        Toggle("Click to Dismiss", isOn: $preferencesManager.blurClickToDismiss)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("When enabled, clicking anywhere dismisses the privacy blur. The click also reaches the app underneath.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                        
                        // ── Blur Preview (notch camera before blur) ──
                        Toggle("Show Camera Preview Before Blur", isOn: $preferencesManager.blurPreviewEnabled)
                        
                        if preferencesManager.blurPreviewEnabled {
                            HStack {
                                Text("Preview Duration")
                                Spacer()
                                Text("\(preferencesManager.blurPreviewDelay, specifier: "%.1f")s")
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            Slider(value: $preferencesManager.blurPreviewDelay, in: 0.5...10, step: 0.5)
                                .help("How long the notch camera preview is shown before the full-screen blur activates")
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("When a shoulder surfer is detected, the camera feed appears in the notch for this duration before the full-screen blur takes effect. During this window you can see who is looking at your screen.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        
                        // Reset
                        HStack {
                            Spacer()
                            Button("Reset Blur to Defaults") {
                                preferencesManager.resetBlurCustomization()
                                ScreenBlurManager.shared.applyCustomization()
                            }
                            .buttonStyle(.link)
                            .foregroundColor(.secondary)
                            .font(.caption)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .padding()
        .frame(width: 480, height: 640)
        .onChange(of: preferencesManager.blurMaterialIndex) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
        .onChange(of: preferencesManager.blurOverlayOpacity) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
        .onChange(of: preferencesManager.blurCustomImagePath) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
        .onChange(of: preferencesManager.blurCustomText) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
        .onChange(of: preferencesManager.blurOverlayColor) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
        .onChange(of: preferencesManager.blurClickToDismiss) { _ in
            ScreenBlurManager.shared.applyCustomization()
        }
    }
    
    // MARK: - Helpers
    
    /// Show an NSOpenPanel to pick a custom image file
    private func browseForImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Blur Background Image"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an image to display as the blur overlay background"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferencesManager.blurCustomImagePath = url.path
    }
    
    /// Shorten a full file path for display (replace home dir with ~)
    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }
}

#Preview {
    SettingsView()
}