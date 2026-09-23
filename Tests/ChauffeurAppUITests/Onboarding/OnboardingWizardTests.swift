import XCTest
import Foundation
import ChauffeurCore

@MainActor final class OnboardingWizardTests: XCTestCase {
    private var fixture: OnboardingUIFixture!

    override func setUp() async throws {
        continueAfterFailure = false
        fixture = OnboardingUIFixture()
        try await fixture.start()
    }

    override func tearDown() async throws {
        await fixture?.stop()
    }

    func testSettingsAddTeamCancelPreservesExistingTeamsAndDraft() async throws {
        _ = try await fixture.seedReturningProject(name: "Existing Project")
        let originalDraft = try await fixture.seedDraft(SetupDraft(teams: [SetupTeam(name: "Unfinished")]))
        fixture.launch()
        fixture.app.typeKey(",", modifierFlags: .command)
        let teams = fixture.app.buttons["Teams"]
        XCTAssertTrue(teams.waitForExistence(timeout: 10))
        teams.click()
        let add = fixture.app.buttons["preset-set.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let name = fixture.app.textFields["preset-set.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertFalse(fixture.app.buttons["onboarding.discard"].exists)
        XCTAssertFalse(fixture.app.buttons["onboarding.continue"].exists)
        name.replaceText(with: "Cancelled team")
        fixture.app.buttons["Cancel"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertTrue(fixture.app.staticTexts["Existing Team"].firstMatch.exists)
        let draftAfterCancel = try await fixture.setupDraft()
        XCTAssertEqual(draftAfterCancel.version, originalDraft.version)

        add.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "")
        name.replaceText(with: "New client")
        fixture.app.buttons["preset-set.save"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
        XCTAssertTrue(fixture.app.staticTexts["New client"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(fixture.app.staticTexts["Existing Team"].firstMatch.exists)
        let draftAfterAdd = try await fixture.setupDraft()
        XCTAssertEqual(draftAfterAdd.version, originalDraft.version)
    }

    func testSingleProfileLoginSummaryAndReturnToWelcome() async throws {
        fixture.launch()
        fixture.openWizard()

        let codex = fixture.app.checkBoxes["onboarding.agent.codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: 10))
        let selected = (codex.value as? Bool) == true
            || (codex.value as? Int) == 1
            || (codex.value as? String) == "1"
        if !selected { codex.click() }
        XCTAssertTrue(codex.isEnabled)
        XCTAssertTrue(fixture.app.descendants(matching: .any)["onboarding.detected.codex"].exists)
        XCTAssertFalse(fixture.app.textFields["onboarding.executable.codex"].exists)
        fixture.app.buttons["onboarding.continue"].click()

        let teamName = fixture.app.textFields["onboarding.teamName"]
        XCTAssertTrue(teamName.waitForExistence(timeout: 10))
        teamName.replaceText(with: "UI Personal")
        fixture.app.buttons["onboarding.continue"].click()

        let stored = try await waitForDraft(step: .configurations)
        let pair = try XCTUnwrap(stored.value.teams.first?.agents.first(where: { $0.kind == .codex }))
        let configuration = fixture.app.descendants(matching: .any)["onboarding.configuration.\(pair.id)"]
        XCTAssertTrue(configuration.waitForExistence(timeout: 10))
        configuration.click()
        let current = fixture.app.menuItems["Use my current configuration"]
        if current.waitForExistence(timeout: 2) { current.click() }
        fixture.app.buttons["onboarding.continue"].click()

        XCTAssertTrue(fixture.app.staticTexts["Sign in to each account"].waitForExistence(timeout: 15))
        let signIn = fixture.app.buttons["onboarding.signIn.codex"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15))
        signIn.click()
        XCTAssertTrue(fixture.app.staticTexts["Connected"].waitForExistence(timeout: 20))

        fixture.app.buttons["onboarding.continue"].click()
        XCTAssertTrue(fixture.app.staticTexts["Your teams are ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(fixture.app.staticTexts["UI Personal"].exists)
        XCTAssertFalse(fixture.app.buttons["onboarding.openProject"].exists)
        XCTAssertFalse(fixture.app.buttons["onboarding.discard"].exists)
        XCTAssertFalse(fixture.app.buttons["onboarding.finishLater"].exists)
        fixture.app.buttons["onboarding.finish"].click()

        let createProject = fixture.app.buttons["Create New Project…"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 15))
        XCTAssertTrue(createProject.isEnabled)
        XCTAssertFalse(fixture.app.staticTexts["Create Project"].exists)
        XCTAssertFalse(fixture.app.buttons["onboarding.finish"].exists)
        let finished = try await fixture.setupDraft()
        XCTAssertTrue(finished.value.completed)

    }

    func testSaveAndFinishLaterResumesPartiallyTypedTeamName() async throws {
        let pair = SetupAgentPair(
            kind: .codex,
            executable: fixture.executable.path,
            choice: .current,
            sourcePath: fixture.profile.path,
            destinationPath: fixture.profile.path
        )
        let team = SetupTeam(name: "Personal", agents: [pair])
        let draft = SetupDraft(
            step: .teams,
            accountCounts: [CLIKind.codex.rawValue: .single],
            executables: [CLIKind.codex.rawValue: fixture.executable.path],
            teams: [team],
            defaultTeamID: team.id
        )
        _ = try await fixture.seedDraft(draft)
        fixture.launch()
        fixture.openWizard()

        let teamName = fixture.app.textFields["onboarding.teamName"]
        XCTAssertTrue(teamName.waitForExistence(timeout: 10))
        teamName.replaceText(with: "Partially Typed Client")
        fixture.app.buttons["onboarding.finishLater"].click()
        XCTAssertTrue(fixture.app.staticTexts["Set up your teams"].waitForNonExistence(timeout: 10))

        let resume = fixture.app.buttons["onboarding.open"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertEqual(resume.label, "Resume Setup…")
        resume.click()
        XCTAssertTrue(fixture.app.staticTexts["Name your teams"].waitForExistence(timeout: 10))
        XCTAssertEqual(fixture.app.textFields["onboarding.teamName"].value as? String, "Partially Typed Client")
        let saved = try await fixture.setupDraft()
        XCTAssertEqual(saved.value.teams.first?.name, "Partially Typed Client")
        XCTAssertTrue(saved.value.dismissed)
    }

    func testReturningUserRestoresExistingProjectWithoutPresentingWizard() async throws {
        let project = try await fixture.seedReturningProject(name: "Existing Project Window")
        fixture.launch()

        XCTAssertTrue(fixture.app.windows[project.name].waitForExistence(timeout: 15))
        XCTAssertFalse(fixture.app.staticTexts["Set up your teams"].waitForExistence(timeout: 3))
        let snapshot = try await fixture.call("snapshot")
        XCTAssertEqual(snapshot["store"]["projects"].array.count, 1)
        let draft = try await fixture.call("setupDraft").decode(Optional<Stored<SetupDraft>>.self)
        XCTAssertNil(draft)
    }

    private func waitForDraft(step: SetupStep, timeout: Duration = .seconds(10)) async throws -> Stored<SetupDraft> {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let stored = try? await fixture.setupDraft(), stored.value.step == step { return stored }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await fixture.setupDraft()
    }
}
