import Foundation

/// Best-effort "is this a Pokemon Essentials fangame?" detector.
enum PokemonEssentialsDetection {
    static func detect(
        in gameDirectory: URL,
        stateDirectory: URL
    ) -> Bool {
        let fm = FileManager.default

        let marker =
            stateDirectory
            .appendingPathComponent(".pokemon_essentials_detected")
        if fm.fileExists(atPath: marker.path) { return true }

        let scriptCandidates = [
            "Data/Scripts.rxdata",
            "Data/Scripts.rvdata",
            "Data/Scripts.rvdata2",
        ]
        let scriptSignatures: [Data] = [
            Data("PokeBattle".utf8),
            Data("PokemonSystem".utf8),
            Data("PokemonEntry".utf8),
            Data("Compiler_PBS".utf8),
        ]
        for relPath in scriptCandidates {
            let url = gameDirectory.appendingPathComponent(relPath)
            guard let data = try? Data(contentsOf: url), data.count > 1024
            else { continue }
            for sig in scriptSignatures where data.range(of: sig) != nil {
                return true
            }
        }

        let dataDir = gameDirectory.appendingPathComponent("Data")
        let peDataMarkers = [
            "abilities.dat", "species.dat", "moves.dat",
            "pokemon.dat", "pokemon_forms.dat", "items.dat",
            "trainer_types.dat", "encounters.dat",
        ]
        for marker in peDataMarkers {
            let url = dataDir.appendingPathComponent(marker)
            if fm.fileExists(atPath: url.path) { return true }
        }

        return false
    }
}
