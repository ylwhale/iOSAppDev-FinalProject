//
//  RadioAtlasApp.swift
//  RadioAtlas
//
//  Created by Jingyu Huang on 2/17/26.
//

import SwiftUI
import UIKit

@main
/// Application entry point that initializes app defaults and the shared audio stack.
struct RadioAtlasApp: App {
    init() {
        // Register Settings.bundle defaults and required launch-tracking values.
        SettingsManager.registerDefaults()
        SettingsManager.handleLaunch()

        // Ensure the audio stack (audio session + remote commands) is configured early.
        // This makes background / lock-screen playback much more reliable.
        _ = AudioManager.shared
    }

    var body: some Scene {
        WindowGroup {
            AppRootContainer()
        }
    }
}

/// Root container used to observe lifecycle (scenePhase) changes for logging and multi-tasking behavior.
/// Scene-aware wrapper that keeps lifecycle logging close to the visible root view.
struct AppRootContainer: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .tint(Color("AccentColor"))
            .onChange(of: scenePhase) { _, newPhase in
                AppLog.info("Scene phase changed: \(String(describing: newPhase))")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                AppLog.info("Application will terminate")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                AppLog.info("Application received memory warning")
            }
    }
}
