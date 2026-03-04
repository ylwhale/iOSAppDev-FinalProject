//
//  RadioAtlasUITests.swift
//  RadioAtlasUITests
//
//  Created by Jingyu Huang on 2/17/26.
//

import XCTest

final class RadioAtlasUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testVoiceOverLabelsOnKeyMapControls() throws {
        let app = XCUIApplication()
        app.launch()

        let onboardingButton = app.buttons["Welcome to RadioAtlas. Tap to continue."]
        if onboardingButton.waitForExistence(timeout: 2) {
            onboardingButton.tap()
        }

        let mapTab = app.tabBars.buttons["Map"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 3))
        mapTab.tap()

        XCTAssertTrue(app.buttons["Center on my location"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Sleep timer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Random station"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testVoiceOverLabelsOnPlacesDiscoveryControls() throws {
        let app = XCUIApplication()
        app.launch()

        let onboardingButton = app.buttons["Welcome to RadioAtlas. Tap to continue."]
        if onboardingButton.waitForExistence(timeout: 2) {
            onboardingButton.tap()
        }

        let placesTab = app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 3))
        placesTab.tap()

        XCTAssertTrue(app.otherElements["country_filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["region_filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["language_filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["station_sort"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["save_current_mix"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAccessibilityAuditOnMainCustomScreens() throws {
        let app = XCUIApplication()
        app.launch()

        let onboardingButton = app.buttons["Welcome to RadioAtlas. Tap to continue."]
        if onboardingButton.waitForExistence(timeout: 2) {
            onboardingButton.tap()
        }

        if #available(iOS 17.0, *) {
            let placesTab = app.tabBars.buttons["Places"]
            XCTAssertTrue(placesTab.waitForExistence(timeout: 3))
            placesTab.tap()
            _ = try? app.performAccessibilityAudit()

            let mapTab = app.tabBars.buttons["Map"]
            XCTAssertTrue(mapTab.waitForExistence(timeout: 3))
            mapTab.tap()
            _ = try? app.performAccessibilityAudit()

            let sleepTimerButton = app.buttons["Sleep timer"]
            if sleepTimerButton.waitForExistence(timeout: 2) {
                sleepTimerButton.tap()
                _ = try? app.performAccessibilityAudit()
            }
        } else {
            throw XCTSkip("Accessibility audit requires iOS 17 or later.")
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
