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
      --prayer-requests  채점 대신 한 페이지 분량 일기 → 기도제목을 이전·새 프롬프트로 만들어
                         나란히 출력 (--only, --list, --json과 함께 쓸 수 있다)
      --serve          프롬프트 실험 페이지를 이 Mac에서만 연다 (http://localhost:8765)
      --port <번호>    --serve 포트 (기본 8765)
      --log-dir <경로> --serve에서 지어낸 일기로 돌린 결과를 lab-runs.jsonl로 남긴다
                       (직접 입력한 일기는 내용을 남기지 않는다)
    """

struct Options {
    var only: Set<String>?
    var list = false
    var includeProse = true
    var verbose = false
    var jsonPath: String?
    var prayerRequests = false
    var serve = false
    var port: UInt16 = 8765
    var logDirectory: String?

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
            case "--prayer-requests": prayerRequests = true
            case "--serve": serve = true
            case "--port":
                guard let value = iterator.next().flatMap(UInt16.init) else { throw UsageError() }
                port = value
            case "--log-dir":
                guard let value = iterator.next() else { throw UsageError() }
                logDirectory = value
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

func saveJSON(_ value: some Encodable, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
        try encoder.encode(value).write(to: URL(fileURLWithPath: path))
        print("JSON 저장: \(path)")
    } catch {
        print("JSON 저장 실패: \(error)")
        exit(1)
    }
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
let diaries = PrayerDiaryFixtures.all.filter { options.only?.contains($0.id) ?? true }
if options.list {
    if options.prayerRequests {
        for diary in PrayerDiaryFixtures.all {
            print("\(diary.id)\t\(diary.date)\t\(diary.body.count)자")
        }
    } else {
        for entry in EvalFixtures.all {
            print("\(entry.id)\t\(entry.kind.rawValue)\t\(entry.date)\t\(entry.body.count)자")
        }
    }
    exit(0)
}
if options.prayerRequests ? diaries.isEmpty : entries.isEmpty {
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

    if options.serve {
        guard let pageURL = Bundle.module.url(forResource: "prompt-lab", withExtension: "html"),
            let page = try? Data(contentsOf: pageURL)
        else {
            print("prompt-lab.html을 찾을 수 없습니다.")
            exit(1)
        }
        let server = PromptLabServer(
            pipeline: pipeline, page: page, port: options.port, logDirectory: options.logDirectory)
        do {
            try server.start()
        } catch {
            print("서버를 열 수 없습니다: \(error)")
            exit(1)
        }
        print("프롬프트 실험 페이지: http://localhost:\(options.port)  (끝내려면 Ctrl-C)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    if options.prayerRequests {
        let generatedAt = Date()
        var results: [PrayerDiaryResult] = []
        print(
            "일기 → 기도제목: 일기 \(diaries.count)개, 프롬프트 \(SharePrompts.prayerRequestVersion) "
                + "(비교: \(SharePrompts.version) 기도 카드)")
        for diary in diaries {
            let result = await pipeline.draftPrayerRequests(diary)
            results.append(result)
            PrayerRequestPrinter.lines(for: result).forEach { print($0) }
        }
        if let path = options.jsonPath {
            saveJSON(
                PrayerRequestRun(
                    promptVersion: SharePrompts.prayerRequestVersion,
                    previousPromptVersion: SharePrompts.version,
                    model: "Apple Foundation Models · SystemLanguageModel (온디바이스)",
                    machine: machineModel(),
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    generatedAt: generatedAt,
                    diaries: results
                ),
                to: path)
        }
        exit(0)
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

    if let path = options.jsonPath { saveJSON(report, to: path) }
    exit(0)
}
#endif

print("이 평가는 macOS 26 이상과 FoundationModels SDK가 필요합니다.")
exit(69)
