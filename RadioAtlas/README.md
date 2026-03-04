# RadioAtlas

RadioAtlas is a SwiftUI iOS app for discovering places through sound. It combines a place browser, a live radio map, and a lightweight audio player so users can explore curated locations, listen to global radio stations, and save the sounds that match their mood. The app is designed to feel faster and simpler than a traditional streaming platform: instead of building playlists, users can tap a place or station, start listening immediately, and keep moving through the app while playback continues.

## What the app does

RadioAtlas blends three ideas into one experience:

- **Place discovery** through curated locations and user-added pins
- **Radio discovery** through searchable global stations shown on a map
- **Ambient listening** through live streams, bundled offline sounds, and quick playback controls

This makes the app useful for studying, relaxing, commuting, virtual travel, and casual exploration.

## Main features

### 1. Places tab
The Places tab is the main browsing hub for curated content.

- Browse a combined list of **places** and **radio stations**
- Switch between **All** and **Favorites** using the segmented control
- Search across place names, place subtitles, categories, and station metadata
- Open detailed cards for places and stations without leaving the app flow
- Use category chips to narrow place browsing by built-in categories such as:
  - Study
  - Food
  - Services
  - Outdoors
  - Housing

### 2. Radio discovery controls
RadioAtlas includes a dedicated discovery area for exploring stations with lightweight filters.

- Filter radio stations by:
  - **Country**
  - **Region**
  - **Language**
- Sort results by:
  - **A-Z**
  - **Favorites First**
  - **Recently Played**
  - **Study Friendly**
  - **Nearest to Me**
- See how many stations currently match the active filters
- Save the current combination of discovery filters as a reusable **listening mix**
- Reopen saved mixes later, rename them, or remove them

This makes it easy to create quick presets for different moods or use cases, such as a study mix, a calm international mix, or a favorites-first local mix.

### 3. Interactive map view
The Map tab provides a map-first exploration experience.

- View places and radio stations as map pins
- Search directly from the map for radio stations or places
- Jump to matching results from the floating search card
- Toggle map presentation between **standard** and **satellite** styles
- Center the map on the user’s current location
- Jump to the station that is currently playing
- Use the **random station** control to fly to a surprise station on the map
- Add a new place pin from map search results

The map is meant to feel like a discovery tool, not just a navigation screen. It encourages quick exploration and serendipitous listening.

### 4. Place detail experience
Each place can open into a richer detail view.

- View place title, subtitle, address, notes, and related metadata
- See an embedded map preview for the selected place
- Open directions-related information
- Mark a place as a favorite
- Reassign a place to a different category when needed
- Launch audio playback associated with that place

Places act as lightweight “audio destinations” that combine location context with sound.

### 5. Station detail and playback
Radio stations can be opened and played directly from lists, search results, or map pins.

- Stream live radio from bundled station data
- View station name, location, and descriptive text
- See available artwork or a cached station logo when provided
- Mark stations as favorites
- Track recently played stations for fast return access
- View now-playing context while the stream is active

### 6. Built-in offline audio
In addition to live streams, RadioAtlas includes bundled offline audio.

- Play built-in loops and music tracks from the app bundle
- Use offline sounds when a live stream is not the right fit
- Keep the app useful even when the user wants a simpler, more controlled sound source

Bundled sounds include ambient loops and prepackaged audio tracks that can support focused listening sessions.

### 7. Mini player and background playback
Playback is designed to stay accessible throughout the app.

- A persistent **mini player bar** stays visible while browsing
- Quick controls let the user:
  - Play or pause
  - Stop playback
  - Favorite the active item
- Audio continues with **background playback** support
- Users can keep listening while switching tabs or navigating between screens

### 8. Sleep timer
RadioAtlas includes a built-in sleep timer for timed listening.

- Set a timer for playback to end automatically after a chosen duration
- View a countdown chip when the timer is active
- Cancel the timer directly from the countdown control

This is especially useful for study sessions, winding down, or short background listening periods.

### 9. Favorites and recents
The app keeps personal listening history lightweight and easy to revisit.

- Save places and stations to **Favorites** with the heart button
- Open the **Recent** tab to revisit recently viewed or played items
- Remove entries from recents when they are no longer needed

### 10. User personalization
RadioAtlas allows users to make map pins more personal.

- Add custom place pins from map search
- Attach **photos** to a pin from the photo library
- Take a photo with the camera and attach it to a pin
- Attach **video** media to supported pins
- Store personal media locally so places can become personal memory markers

This gives the app a more personal, scrapbook-like quality rather than feeling like a static station list.

### 11. Onboarding, splash, and help
The project includes built-in guidance for first-time use.

- A full-screen in-app **splash screen** appears on launch
- The splash screen includes the app name and developer name
- A multi-screen **onboarding flow** introduces the core experience
- A built-in **Help / Instructions** view explains how to use the app later

### 12. Settings and launch behavior
The app includes user defaults and required project-side launch handling.

- Includes a `Settings.bundle`
- Registers default preferences on launch
- Stores the required **Initial Launch** timestamp
- Tracks launch count
- Shows a custom **Rate this App in the App Store** alert on the third launch

## Technical overview

RadioAtlas is built with **SwiftUI** and Apple’s native frameworks for the core experience.

- **SwiftUI** for the interface and app flow
- **MapKit** for map rendering, search, and pin-based exploration
- **AVFoundation / AVKit** for audio playback and media presentation
- **PhotosUI** and UIKit pickers for attaching photos and videos
- **UserDefaults** for preferences, recents, saved mixes, and lightweight persistence
- **Bundled JSON** files for place and station seed data
- **Alamofire** for downloading and caching remote station logos

The app is structured so that the third-party framework is supplemental rather than central: the main product behavior is implemented with app code and Apple frameworks.

## Accessibility and user experience details

RadioAtlas is designed to be comfortable to use in normal and low-friction listening scenarios.

- Custom controls include accessibility labels and hints for VoiceOver support
- Loading and buffering states surface progress feedback
- Playback failures can present a user-facing alert
- The app retries streaming when connectivity returns
- The mini player keeps core playback controls reachable from anywhere

## Device support

- Universal app for **iPhone and iPad**
- Designed for touch-first navigation with large tap targets, tab-based movement, and sheet-based detail views

## Project contents

The project bundle includes:

- `RadioAtlas.xcodeproj`
- `RadioAtlas/` source files and assets
- `Settings.bundle`
- Bundled audio and JSON resources
- Marketing materials and executive summary PDFs
- Test targets for app and UI testing

## Build and run

1. Open `RadioAtlas.xcodeproj` in Xcode.
2. Select the **RadioAtlas** target.
3. Build and run on an iPhone or iPad simulator, or on a physical device.
4. On first launch, review the splash/onboarding flow and confirm playback behavior.

## Summary

RadioAtlas is a location-inspired audio exploration app that makes discovery feel immediate. It combines curated places, world radio, offline ambient audio, personal media attachments, saved favorites, recent history, and always-available playback controls in one focused iOS experience. The result is an app that works both as a practical listening tool and as a more personal way to explore places through sound.
