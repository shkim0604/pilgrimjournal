import Foundation

// Re-runnable eval of the planned share-card extraction on Apple's on-device model. Needs
// macOS 26 with Apple Intelligence enabled, so it is not part of scripts/check.sh or CI; see
// docs/development.md "공유 카드 추출 평가".

let usage = """
    사용법: swift run ShareCardEval [옵션]
      --only id1,id2   해당 기록만 실행
      --list           기록 id 목록만 출력
      --skip-prose     카드 문장(자유 텍스트) 생성을 건너뛴다. 점수는 같고 더 빠르다
      --verbose        모델 결과(기도제목, 카드 문장)를 함께 출력
      --json <경로>    결과를 JSON으로 저장 (저장소 밖 경로 권장)
    """

struct Options {
    var only: Set<String>?
    var list = false
    var includeProse = true
    var verbose = false
    var jsonPath: String?

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--only":
                guard let value = iterator.next() else { throw UsageError() }
                only = Set(value.split(separator: ",").map(String.init))
            case "--list": list = true
            case "--skip-prose": includeProse = false
            case "--verbose": verbose = true
            case "--json":
                guard let value = iterator.next() else { throw UsageError() }
                jsonPath = value
            default: throw UsageError()
            }
        }
    }
}

struct UsageError: Error {}

func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func verboseLines(_ result: EntryResult) -> [String] {
    var lines: [String] = []
    let answers = result.prediction.answers.sorted { $0.key < $1.key }
    if !answers.isEmpty {
        lines.append(
            "    분류 답: " + answers.map { "\($0.key) \($0.value)" }.joined(separator: " | "))
    }
    for item in result.prediction.prayerItems {
        let date = item.finalDate?.description ?? "-"
        lines.append("    · \(item.summary) | \"\(item.datePhrase)\" → \(date)")
    }
    if let book = result.prediction.book {
        lines.append("    · 『\(book.title)』 \(book.author) | \(book.quote)")
    }
    for (name, prose) in result.prediction.prose.sorted(by: { $0.key < $1.key }) {
        lines.append("    [\(name)] " + prose.replacingOccurrences(of: "\n", with: "\n      "))
    }
    for call in result.calls where call.outcome != "ok" {
        lines.append("    ! \(call.step): \(call.outcome)")
    }
    return lines
}

let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    print(usage)
    exit(64)
}

let entries = EvalFixtures.all.filter { options.only?.contains($0.id) ?? true }
if options.list {
    for entry in EvalFixtures.all {
        print("\(entry.id)\t\(entry.kind.rawValue)\t\(entry.date)\t\(entry.body.count)자")
    }
    exit(0)
}
if entries.isEmpty {
    print("실행할 기록이 없습니다. --list로 id를 확인하세요.")
    exit(64)
}

#if canImport(FoundationModels)
if #available(macOS 26, iOS 26, *) {
    let pipeline = SharePipeline(includeProse: options.includeProse)
    if let problem = pipeline.availabilityProblem {
        print(problem)
        exit(69)
    }

    let startedAt = Date()
    var results: [EntryResult] = []
    print("공유 카드 평가: 기록 \(entries.count)개, 프롬프트 \(SharePrompts.version)")
    for entry in entries {
        let result = await pipeline.run(entry)
        results.append(result)
        print(ReportPrinter.line(for: result))
        ReportPrinter.failures(for: result).forEach { print($0) }
        if options.verbose { verboseLines(result).forEach { print($0) } }
    }

    let report = RunReport(
        promptVersion: SharePrompts.version,
        startedAt: startedAt,
        machine: machineModel(),
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        entries: results
    )
    print(ReportPrinter.summary(report))

    if let path = options.jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
            print("JSON 저장: \(path)")
        } catch {
            print("JSON 저장 실패: \(error)")
            exit(1)
        }
    }
    exit(0)
}
#endif

print("이 평가는 macOS 26 이상과 FoundationModels SDK가 필요합니다.")
exit(69)
