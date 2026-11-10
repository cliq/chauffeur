import XCTest
import ChauffeurRemoteProtocol
@testable import Chauffeur

@MainActor
final class NewSessionFlowTests: XCTestCase {
    private func fixture() throws -> (model: MobileAppModel, chauffeur: ProjectSummary, notes: ProjectSummary) {
        let model = MobileAppModel.preview()
        let projects = try XCTUnwrap(model.inventory?.projects)
        let chauffeur = try XCTUnwrap(projects.first { $0.name == "Chauffeur" })
        let notes = try XCTUnwrap(projects.first { $0.name == "Notes" })
        return (model, chauffeur, notes)
    }

    // MARK: - Skipping single-choice steps

    func testSeveralProjectsStartOnTheProjectList() throws {
        let (model, _, _) = try fixture()
        XCTAssertEqual(model.newSessionRoute(), .newSession)
    }

    func testAProjectWithSeveralRepositoriesOpensItsRepositories() throws {
        let (model, chauffeur, _) = try fixture()
        XCTAssertEqual(model.newSessionRoute(projectID: chauffeur.id), .repository(projectID: chauffeur.id))
    }

    func testARepositoryOpensItsCheckouts() throws {
        let (model, chauffeur, _) = try fixture()
        let folder = chauffeur.folders[0]
        XCTAssertEqual(model.newSessionRoute(projectID: chauffeur.id, folderID: folder.id),
                       .checkout(projectID: chauffeur.id, folderID: folder.id))
    }

    func testAPlainFolderWithOneCheckoutGoesStraightToLaunch() throws {
        let (model, _, notes) = try fixture()
        let folder = notes.folders[0]
        let expected = LaunchLocation(projectID: notes.id, folderID: folder.id, checkout: .existing(path: folder.checkouts[0].path))
        XCTAssertEqual(model.newSessionRoute(projectID: notes.id), .launch(expected))
    }

    func testStartingFromAProjectPushesOnlyItsFirstScreen() throws {
        let (model, chauffeur, _) = try fixture()
        model.startNewSession(projectID: chauffeur.id)
        XCTAssertEqual(model.path, [.sessions, .repository(projectID: chauffeur.id)])
    }

    // MARK: - Suspended projects

    func testASuspendedProjectOffersItsRestoreInsteadOfLaunching() throws {
        let (model, chauffeur, notes) = try fixture()
        let research = try XCTUnwrap(model.inventory?.projects.first { $0.name == "Research" })
        XCTAssertEqual(model.suspendedProjects.map(\.id), [research.id])
        XCTAssertFalse(model.isSuspended(projectID: chauffeur.id) || model.isSuspended(projectID: notes.id))
        XCTAssertEqual(model.suspendedSessions(projectID: research.id).count, 2)
        XCTAssertEqual(model.newSessionRoute(projectID: research.id), .restoreProject(projectID: research.id))
        XCTAssertEqual(model.newSessionRoute(projectID: research.id, folderID: research.folders[0].id), .restoreProject(projectID: research.id))
        // Suspended sessions aren't live, and their checkouts aren't offered as recent launches.
        XCTAssertFalse(model.liveSessions.contains { $0.projectID == research.id })
        XCTAssertFalse(model.recentLocations(limit: 10).contains { $0.projectID == research.id })
    }

    // MARK: - Recent locations

    func testRecentLocationsListEachCheckoutOnceNewestFirst() throws {
        let (model, chauffeur, notes) = try fixture()
        let notesFolder = notes.folders[0]
        let notesPath = notesFolder.checkouts[0].path
        model.recordRecentLaunch(projectID: notes.id, folderID: notesFolder.id, checkoutPath: notesPath, date: Date().addingTimeInterval(60))

        let recents = model.recentLocations(limit: 10)

        XCTAssertEqual(recents.first, LaunchLocation(projectID: notes.id, folderID: notesFolder.id, checkout: .existing(path: notesPath)))
        let paths = recents.compactMap { location -> String? in
            guard case .existing(let path) = location.checkout else { return nil }
            return path
        }
        XCTAssertEqual(paths.count, Set(paths).count, "Each checkout appears once")
        XCTAssertTrue(recents.dropFirst().allSatisfy { $0.projectID == chauffeur.id })
    }

    func testRecentLocationsLeaveOutCheckoutsTheMacNoLongerOffers() throws {
        let (model, chauffeur, _) = try fixture()
        model.recordRecentLaunch(projectID: chauffeur.id, folderID: chauffeur.folders[0].id,
                                 checkoutPath: "/Users/leo/Chauffeur/.worktrees/removed", date: Date().addingTimeInterval(60))

        XCTAssertFalse(model.recentLocations(limit: 10).contains { $0.checkout == .existing(path: "/Users/leo/Chauffeur/.worktrees/removed") })
    }

    func testRecentLocationsRespectTheLimit() throws {
        let (model, _, _) = try fixture()
        XCTAssertEqual(model.recentLocations(limit: 2).count, 2)
    }

    // MARK: - Search

    func testABranchWordFindsItsWorktree() throws {
        let (model, _, _) = try fixture()
        let search = LaunchSearch(query: "mobile", projects: model.inventory?.projects ?? [])

        XCTAssertEqual(search.checkouts.map(\.checkout.branch), ["feature/mobile"])
        XCTAssertTrue(search.projects.isEmpty)
        XCTAssertTrue(search.repositories.isEmpty)
    }

    func testAProjectNameListsTheProjectAndRepositoriesButNotEveryCheckout() throws {
        let (model, _, _) = try fixture()
        let search = LaunchSearch(query: "Chauffeur", projects: model.inventory?.projects ?? [])

        XCTAssertEqual(search.projects.map(\.name), ["Chauffeur"])
        XCTAssertEqual(search.repositories.map(\.folder.name), ["Chauffeur", "chauffeur-cli", "chauffeur-site"])
        XCTAssertTrue(search.checkouts.isEmpty)
    }

    func testEveryWordMustMatchSomewhere() throws {
        let (model, _, _) = try fixture()
        let projects = model.inventory?.projects ?? []

        XCTAssertEqual(LaunchSearch(query: "site pricing", projects: projects).checkouts.map(\.checkout.branch), ["copy/pricing-page"])
        XCTAssertTrue(LaunchSearch(query: "notes pricing", projects: projects).isEmpty)
    }

    func testAPlainFolderMatchesAsARepositoryOnly() throws {
        let (model, _, _) = try fixture()
        let search = LaunchSearch(query: "notes", projects: model.inventory?.projects ?? [])

        XCTAssertEqual(search.projects.map(\.name), ["Notes"])
        XCTAssertEqual(search.repositories.map(\.folder.name), ["notes"])
        XCTAssertTrue(search.checkouts.isEmpty)
    }

    // MARK: - Worktree draft

    func testAnExistingBranchDraftIgnoresTheStartingPoint() {
        let draft = NewWorktreeDraft(branch: "feature/mobile", baseRef: "main", reuseExistingBranch: true)
        XCTAssertEqual(draft.spec, WorktreeCreationSpec(branch: "feature/mobile", baseRef: "HEAD", reuseExistingBranch: true))
    }

    func testHomeFoldersAreAbbreviated() {
        XCTAssertEqual(abbreviatedPath("/Users/leo/Projects/app"), "~/Projects/app")
        XCTAssertEqual(abbreviatedPath("/home/dietpi/app"), "~/app")
        XCTAssertEqual(abbreviatedPath("/Volumes/Work/app"), "/Volumes/Work/app")
    }
}
