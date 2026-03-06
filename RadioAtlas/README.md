# RadioAtlas (MPCS51030 Final Project)

RadioAtlas is a SwiftUI iOS app that helps users explore curated places, discover global radio stations on a map, stream live audio, play bundled local tracks, and save favorites for quick return visits.

## App Store Positioning
- **Category:** Music
- **Age Group:** 4+
- **Device Support:** Universal iPhone + iPad (`TARGETED_DEVICE_FAMILY = 1,2`)

## Core Features
- **Places + Map exploration:** Browse the Places tab or tap pins on the Map to open detailed cards.
- **Streaming radio + offline tracks:** Play live station streams or bundled local audio with background playback support.
- **Favorites + Recents:** Save stations and places with the heart button and revisit recent listening quickly.
- **User-created content:** Add custom place pins and attach photos or videos.
- **Mini Player Bar:** Persistent playback controls stay available while moving between tabs.
- **Launch splash + onboarding:** A full-screen in-app splash screen appears at launch, then transitions into a three-screen onboarding flow.
- **Help sheet + settings:** Built-in instructions are available from the `?` button, and `Settings.bundle` stores required preferences.

## Final Project Rubric Coverage (App-Side)
- **No code warnings intended:** Changes were kept additive and scoped to the existing project structure.
- **Verbose comments:** Custom types and many custom methods include succinct descriptions for graders.
- **Logging:** Critical actions, file paths, URLs, downloads, and lifecycle transitions are printed with the `[RadioAtlas]` prefix.
- **Splash Screen:** Separate full-screen in-app splash overlay (not the static `LaunchScreen`) includes the app name and developer name, dismisses after ~2 seconds, and can also dismiss on tap.
- **Application Use Instructions:** The launch splash, onboarding flow, and Help sheet explain how to use the app.
- **Accessibility:** Custom controls include accessibility labels / hints and the project is designed for VoiceOver testing.
- **Connectivity:** Radio buffering state surfaces a spinner, playback failures show a user-facing alert, and the app retries streams when connectivity returns.
- **Settings.bundle:** Includes developer name and required `Initial Launch` storage in `UserDefaults`.
- **Rate Prompt:** Custom “Rate this App in the App Store” alert appears on the third launch.

## Third-Party Frameworks
- **Alamofire** (resolved through Swift Package Manager) is used to download and cache remote station logos.
- The framework is supplemental only; core app behavior (maps, playback, persistence, splash/onboarding, settings, favorites, recents, and media attachments) is implemented with Apple frameworks and app code.
- The Alamofire integration lives in `RadioAtlas/App/AlamofireStationLogo.swift` and is documented in source comments for graders.
- No known third-party warning issue links are currently required for this project because the app code is intended to build cleanly with the resolved package.

## Build / Run
1. Open `RadioAtlas.xcodeproj` in Xcode.
2. Allow Swift Package Manager to resolve **Alamofire** the first time the project opens.
3. Select the **RadioAtlas** target.
4. Build and run on an iPhone or iPad simulator (or a physical device for final validation).
5. Confirm the launch splash, onboarding flow, settings defaults, and audio playback permissions the first time the app runs.

## Rubric-Oriented Validation Notes
- **Settings.bundle:** The project includes a developer row, app version row, onboarding toggle, and the required `Initial Launch` preference key.
- **Launch tracking:** `SettingsManager` registers defaults at startup, stores the first-launch `Date`, increments launch count, and schedules the custom third-launch rate alert.
- **Lifecycle handling:** `RadioAtlasApp` logs scene-phase transitions, memory warnings, and termination notifications to make multi-tasking behavior visible during grading.
- **Connectivity UX:** Radio playback failures surface a user-facing alert and remote logo loading shows a spinner plus a placeholder fallback.
- **Instructions:** Users can access onboarding at launch and a help sheet from the app UI.
- **Assets included:** Audio loops, bundled JSON, icon assets, settings files, and marketing materials are checked into the project tree so a grader can clone/download and run the app.

## Included Submission Materials
- `MarketingMaterials/jingyu-huang_marketing.pdf`
- `MarketingMaterials/jingyu-huang_executive.pdf`
- `Settings.bundle`
- `README.md`

## Final Manual Submission Notes
- Record the required **App Preview** video separately before final submission.
- If your GitHub username is different from `jingyu-huang`, rename the marketing PDFs to match the final repository username before submitting.
