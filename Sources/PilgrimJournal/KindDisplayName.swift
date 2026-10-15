import Foundation
import JournalDomain

extension BuiltInKind {
    /// The built-in name in the app's language. `defaultName` stays the
    /// Korean name: it is what the kind catalog stores and syncs, so a device
    /// in another language never writes its translation into shared data.
    var localizedDefaultName: String {
        switch self {
        case .prayer: String(localized: "기도노트")
        case .bibleStudy: String(localized: "성경공부")
        case .reading: String(localized: "독서노트")
        case .diary: String(localized: "일기")
        case .memo: String(localized: "메모")
        case .unclassified: String(localized: "미분류")
        }
    }
}

extension KindDefinition {
    /// The name to show. A built-in kind the user never renamed keeps its
    /// Korean default in the catalog (reordering or recolouring stores it
    /// too), so it is shown in the app's language; any other name is the
    /// user's own and is shown as typed.
    var displayName: String {
        if let builtIn = kind.builtIn {
            return name == builtIn.defaultName ? builtIn.localizedDefaultName : name
        }
        if name == KindCatalog.unknownDefinition(for: kind).name {
            return String(localized: "이름 없는 유형")
        }
        return name
    }

    /// The name to store for what the user typed into the kind editor:
    /// leaving a built-in's translated default as it was keeps the Korean
    /// default in the catalog, so other devices keep showing it in their own
    /// language.
    func storedName(for typedName: String) -> String {
        guard let builtIn = kind.builtIn,
            typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                == builtIn.localizedDefaultName
        else { return typedName }
        return builtIn.defaultName
    }
}
