// Writes the SwiftData schema as the admin console reads it (web/admin/snapshot/schema.json).
// Run through scripts/admin-snapshot.sh; scripts/check.sh fails when the committed file is stale.
// Structure only: no records, no fixture content.

#if PILGRIM_SWIFTDATA
import Foundation
import JournalData
import SwiftData

struct SchemaSnapshot: Encodable {
    var schemaVersion: String
    var stores: [Store]
}

struct Store: Encodable {
    var name: String
    var cloudKitSynced: Bool
    var entities: [Entity]
}

struct Entity: Encodable {
    var name: String
    var attributes: [Attribute]
    var relationships: [Relationship]
}

struct Attribute: Encodable {
    var name: String
    var type: String
    var optional: Bool
    var unique: Bool
    var externalStorage: Bool
    var transformable: Bool
}

struct Relationship: Encodable {
    var name: String
    var destination: String
    var toMany: Bool
    var deleteRule: String
    var inverse: String?

    private enum CodingKeys: String, CodingKey {
        case name, destination, toMany, deleteRule, inverse
    }

    // Always emit `inverse`, as null when absent, so the JSON shape is fixed.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(destination, forKey: .destination)
        try container.encode(toMany, forKey: .toMany)
        try container.encode(deleteRule, forKey: .deleteRule)
        try container.encode(inverse, forKey: .inverse)
    }
}

func deleteRuleName(_ rule: Schema.Relationship.DeleteRule) -> String {
    switch rule {
    case .cascade: return "cascade"
    case .nullify: return "nullify"
    case .deny: return "deny"
    case .noAction: return "noAction"
    @unknown default: return "unknown"
    }
}

func store(named name: String, cloudKitSynced: Bool, models: [any PersistentModel.Type]) -> Store {
    let schema = Schema(models)
    let entities = schema.entities.map { entity in
        Entity(
            name: entity.name,
            attributes: entity.attributes.map { attribute in
                Attribute(
                    name: attribute.name,
                    type: String(describing: attribute.valueType),
                    optional: attribute.isOptional,
                    unique: attribute.isUnique,
                    externalStorage: attribute.options.contains(.externalStorage),
                    transformable: attribute.isTransformable
                )
            }
            .sorted { $0.name < $1.name },
            relationships: entity.relationships.map { relationship in
                Relationship(
                    name: relationship.name,
                    destination: relationship.destination,
                    toMany: !relationship.isToOneRelationship,
                    deleteRule: deleteRuleName(relationship.deleteRule),
                    inverse: relationship.inverseName
                )
            }
            .sorted { $0.name < $1.name }
        )
    }
    return Store(
        name: name,
        cloudKitSynced: cloudKitSynced,
        entities: entities.sorted { $0.name < $1.name }
    )
}

let arguments = CommandLine.arguments.dropFirst()
guard let outputDirectory = arguments.first else {
    FileHandle.standardError.write(Data("usage: AdminSnapshot <output-directory>\n".utf8))
    exit(64)
}

let snapshot = SchemaSnapshot(
    schemaVersion: JournalContainerFactory.schemaVersionString,
    stores: [
        store(
            named: "Canonical",
            cloudKitSynced: true,
            models: JournalContainerFactory.canonicalModels
        ),
        store(
            named: "LocalAuxiliary",
            cloudKitSynced: false,
            models: JournalContainerFactory.localModels
        ),
    ]
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(snapshot)
data.append(Data("\n".utf8))

let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try data.write(to: directory.appendingPathComponent("schema.json"), options: .atomic)
#else
import Foundation

FileHandle.standardError.write(Data("AdminSnapshot needs SwiftData (macOS/iOS).\n".utf8))
exit(1)
#endif
