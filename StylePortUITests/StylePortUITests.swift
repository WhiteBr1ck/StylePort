import XCTest

nonisolated final class StylePortUITests: XCTestCase {
  @MainActor
  func testImportTabSwitchClearAndConversionSummary() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["导入照片"].waitForExistence(timeout: 5))

    selectFirstPhoto(in: app)
    XCTAssertTrue(app.buttons["conversion.convert"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["清空"].exists)
    app.tabBars.buttons["设置"].tap()
    app.tabBars.buttons["转换"].tap()
    XCTAssertTrue(app.buttons["conversion.convert"].isEnabled)
    XCTAssertFalse(app.activityIndicators.firstMatch.exists)

    app.buttons["清空"].tap()
    XCTAssertFalse(app.buttons["conversion.convert"].exists)
    XCTAssertTrue(app.buttons["导入照片"].exists)

    selectFirstPhoto(in: app)
    XCTAssertTrue(app.buttons["conversion.convert"].waitForExistence(timeout: 15))
    app.buttons["conversion.convert"].tap()
    XCTAssertTrue(app.navigationBars["转换完成"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts["成功"].exists)
    XCTAssertTrue(app.staticTexts["失败"].exists)
    XCTAssertTrue(app.staticTexts["跳过"].exists)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["导入照片"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["conversion.convert"].exists)
    XCTAssertFalse(app.buttons["清空"].exists)
  }

  @MainActor
  func testMultipleSelectionShowsCompletion() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-three-imports"]
    app.launch()
    XCTAssertTrue(app.buttons["conversion.convert"].waitForExistence(timeout: 20))
    app.buttons["conversion.convert"].tap()
    XCTAssertTrue(app.navigationBars["转换完成"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts["成功"].exists)
    XCTAssertTrue(app.staticTexts["失败"].exists)
    XCTAssertTrue(app.staticTexts["跳过"].exists)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Multiple Photo Completion"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["导入照片"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["conversion.convert"].exists)
  }

  @MainActor
  private func selectFirstPhoto(in app: XCUIApplication, count: Int = 1) {
    app.buttons["导入照片"].tap()
    let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 20))
    photo.tap()
    for index in 1..<count {
      app.images.matching(identifier: "PXGGridLayout-Info").element(boundBy: index).tap()
    }
    let add = app.buttons.matching(
      NSPredicate(
        format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label == %@ OR label == %@",
        "添加", "Add", "完成", "Done"
      )
    ).firstMatch
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.tap()
  }

  @MainActor
  func testPhotosAndSettingsTabs() throws {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["转换"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["导入照片"].exists)
    XCTAssertFalse(app.buttons["conversion.convert"].exists)
    XCTAssertFalse(app.tabBars.buttons["相册"].exists)

    app.tabBars.buttons["查看"].tap()
    XCTAssertTrue(app.navigationBars["查看"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["查看照片信息"].exists)
    XCTAssertTrue(app.staticTexts["选择一张照片查看摄影风格、拍摄参数与图像元数据，可选两张照片进行对照。"].exists)
    XCTAssertTrue(app.buttons["inspect.choosePhotos"].firstMatch.exists)

    app.tabBars.buttons["设置"].tap()

    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["语言"].exists)
    let version = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value == %@", "0.0.1", "0.0.1")
    ).firstMatch
    XCTAssertTrue(version.waitForExistence(timeout: 5))
    XCTAssertTrue(app.segmentedControls.firstMatch.exists)
    let replaceSwitch = app.switches["替换原照片"]
    XCTAssertTrue(replaceSwitch.exists)
    XCTAssertEqual(replaceSwitch.value as? String, "0")
    XCTAssertFalse(app.staticTexts["转换核心为 StylePort 独立实现。本应用与 Apple 无隶属关系。"].exists)
    XCTAssertFalse(app.staticTexts["转换说明"].exists)
    XCTAssertFalse(app.staticTexts["面向 iPhone 原始 HEIC"].exists)
    XCTAssertFalse(app.staticTexts["推荐组合"].exists)

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "StylePort Settings"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testInspectionSurvivesTabSwitchAndClears() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-inspection"]
    app.launch()
    app.tabBars.buttons["查看"].tap()
    XCTAssertTrue(app.staticTexts["InspectionFixture.png"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["摄影风格"].exists)
    XCTAssertFalse(app.staticTexts["具体风格名称与调节值"].exists)
    XCTAssertFalse(app.staticTexts["暂无法可靠解读"].exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "数据存在不等于")).firstMatch.exists)
    app.tabBars.buttons["设置"].tap()
    app.tabBars.buttons["查看"].tap()
    XCTAssertTrue(app.staticTexts["InspectionFixture.png"].exists)
    XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Photo Information"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["清空"].tap()
    XCTAssertTrue(app.staticTexts["查看照片信息"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["InspectionFixture.png"].exists)
  }

}
