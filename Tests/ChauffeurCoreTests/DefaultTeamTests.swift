import ChauffeurCore
import Foundation
import Testing

struct DefaultTeamTests {
    private func stored(_ set: PresetSet) throws -> Stored<PresetSet> {
        struct Raw: Encodable { let value: PresetSet; let path: String; let version: String }
        return try JSONCoding.decode(Stored<PresetSet>.self, from: JSONCoding.encode(Raw(value: set, path: "/tmp/\(set.id).json", version: "v")))
    }

    @Test func legacyTeamRecordsDecodeWithoutTheFlag() throws {
        let legacy = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Team","revision":2,"archived":false}"#.utf8)
        let set = try JSONCoding.decode(PresetSet.self, from: legacy)
        #expect(set.isDefault == false)
        #expect(set.revision == 2)
        var flagged = set; flagged.isDefault = true
        #expect(try JSONCoding.decode(PresetSet.self, from: JSONCoding.encode(flagged)).isDefault)
    }

    @Test func flaggedTeamWinsOtherwiseFirstUsableByName() throws {
        var zeta = PresetSet(name: "Zeta"), alpha = PresetSet(name: "alpha"), archived = PresetSet(name: "Aardvark")
        archived.archived = true
        var snapshot = StoreSnapshot()
        snapshot.presetSets = [try stored(zeta), try stored(alpha), try stored(archived)]
        #expect(snapshot.defaultPresetSet?.id == alpha.id)
        zeta.isDefault = true
        snapshot.presetSets = [try stored(zeta), try stored(alpha), try stored(archived)]
        #expect(snapshot.defaultPresetSet?.id == zeta.id)
        snapshot.presetSets = [try stored(archived)]
        #expect(snapshot.defaultPresetSet == nil)
    }

    @Test func defaultTeamCannotBeArchived() {
        var set = PresetSet(name: "Team"); set.isDefault = true; set.archived = true
        #expect(throws: ChauffeurError.self) { try set.validate() }
    }
}
