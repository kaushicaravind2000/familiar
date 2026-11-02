// swift-tools-version: 5.10
import PackageDescription

// Familiar: find files on this Mac by what's in them, with EmbeddingGemma 2 running locally on llama.cpp.
//   FamiliarCore  the engine: model files, the llama-server helper, readers, the SQLite index, search. No UI.
//   FamiliarApp  the menu-bar app (build.sh wraps it into build/Familiar.app).
//   fam             a command-line tool for indexing and searching from the terminal, handy for testing.
//   Int8Kernels     the 8-bit search kernel in C, for the NEON dot-product instruction Swift can't reach.
let package = Package(
    name: "Familiar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FamiliarApp", targets: ["FamiliarApp"]),
        .executable(name: "fam", targets: ["fam"]),
    ],
    targets: [
        .target(name: "Int8Kernels"),
        .target(name: "FamiliarCore", dependencies: ["Int8Kernels"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FamiliarApp", dependencies: ["FamiliarCore"]),
        .executableTarget(name: "fam", dependencies: ["FamiliarCore"]),
    ]
)
