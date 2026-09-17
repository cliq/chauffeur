import ChauffeurRemoteProtocol
import Foundation
import Testing

struct PairingKeyDerivationTests {
    @Test func normalizesSeparatorsCaseAndLookalikes() {
        #expect(PairingKeyDerivation.normalize("k7q2-9mjx-4t") == "K7Q29MJX4T")
        #expect(PairingKeyDerivation.normalize("K7Q2 9MJX 4T") == "K7Q29MJX4T")
        #expect(PairingKeyDerivation.normalize("i7q2-9mlx-4o") == "17Q29M1X40")
    }

    @Test func rejectsWrongLengthAndForeignCharacters() {
        #expect(PairingKeyDerivation.normalize("K7Q29MJX4") == nil)
        #expect(PairingKeyDerivation.normalize("K7Q29MJX4TT") == nil)
        #expect(PairingKeyDerivation.normalize("K7Q29MJX4U") == nil)
    }

    @Test func displayGroupsFourFourTwo() {
        #expect(PairingKeyDerivation.display("K7Q29MJX4T") == "K7Q2-9MJX-4T")
    }

    @Test func derivationIsDeterministicAndCodeSpecific() {
        let a = PairingKeyDerivation.derive(normalizedCode: "K7Q29MJX4T")
        let b = PairingKeyDerivation.derive(normalizedCode: "K7Q29MJX4T")
        let c = PairingKeyDerivation.derive(normalizedCode: "K7Q29MJX4V")
        #expect(a.count == 32)
        #expect(a == b)
        #expect(a != c)
    }
}
