// swift-tools-version: 5.10
import PackageDescription

// Familiar: find files on this Mac by what's in them, with EmbeddingGemma 2 running locally on llama.cpp.
//   FamiliarCore  the engine: model files, the llama-server helper, readers, the SQLite index, search. No UI.
//   FamiliarApp  the menu-bar app (build.sh wraps it into build/Familiar.app).
//   fam             a command-line tool for indexing and searching from the terminal, handy for testing.
let package = Package(
    name: "Familiar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FamiliarApp", targets: ["FamiliarApp"]),
        .executable(name: "fam", targets: ["fam"]),
    ],
    targets: [
        .target(name: "FamiliarCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FamiliarApp", dependencies: ["FamiliarCore"]),
        .executableTarget(name: "fam", dependencies: ["FamiliarCore"]),
    ]
)
