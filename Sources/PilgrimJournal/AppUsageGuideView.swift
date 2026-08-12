import SwiftUI

enum AppUsageGuidePlatform: Equatable {
    case iOS
    case macOS
}

struct AppUsageGuideItem: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
}

struct AppUsageGuideSection: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let items: [AppUsageGuideItem]
}

enum AppUsageGuideContent {
    static let commonSections = [
        AppUsageGuideSection(
            id: "getting-started",
            title: "시작하기",
            systemImage: "square.and.pencil",
            items: [
                AppUsageGuideItem(
                    id: "create-entry",
                    title: "새 기록 만들기",
                    body: "기록 목록의 ‘새 노트’ 또는 도구 막대의 작성 버튼을 누르세요. 기록 정보를 열어 유형과 날짜를 정하고 제목과 본문을 작성하면 변경 내용이 자동으로 저장됩니다."
                ),
                AppUsageGuideItem(
                    id: "entry-types",
                    title: "다섯 가지 기록 유형",
                    body: "기도노트에는 기도 상태와 응답일, 성경공부에는 구절, 독서노트에는 책과 저자, 일기에는 기분을 남길 수 있습니다. 간단한 내용은 메모로 기록하세요."
                ),
                AppUsageGuideItem(
                    id: "edit-entry",
                    title: "기록 편집하기",
                    body: "목록에서 기록을 선택해 제목, 본문, 날짜, 유형과 태그를 수정하세요. 저장된 변경은 수정 이력에 남으며 이전 내용을 새 revision으로 복원할 수 있습니다."
                ),
                AppUsageGuideItem(
                    id: "attachments",
                    title: "첨부파일 추가와 미리보기",
                    body: "편집 화면의 ‘파일’로 사진, 동영상, 오디오, PDF를 더하거나 ‘사진’으로 사진 보관함에서 여러 장을 한 번에 고르세요. iPhone에서는 ‘촬영’으로 카메라를 바로 열어 찍은 사진을 첨부할 수 있습니다. 이 기기에 저장된 첨부는 눈 모양 아이콘으로 바로 미리 보고, 저장 아이콘으로 다른 위치에 저장할 수 있습니다. 아직 받지 않은 첨부는 먼저 ‘다운로드’를 눌러야 합니다."
                ),
            ]
        ),
        AppUsageGuideSection(
            id: "organize-and-find",
            title: "분류와 찾기",
            systemImage: "line.3.horizontal.decrease.circle",
            items: [
                AppUsageGuideItem(
                    id: "organize",
                    title: "태그와 노트북으로 정리하기",
                    body: "편집 화면에서 태그와 노트북을 지정하세요. 설정의 ‘태그 및 Day One 분류 규칙’에서는 태그 이름을 관리하고 가져온 기록의 유형 분류 규칙을 정할 수 있습니다."
                ),
                AppUsageGuideItem(
                    id: "search",
                    title: "기록 검색하기",
                    body: "기록 목록의 검색 칸에 제목, 본문 또는 태그를 입력하세요. 검색이 예상대로 되지 않으면 설정에서 ‘검색 인덱스 다시 만들기’를 실행할 수 있습니다."
                ),
                AppUsageGuideItem(
                    id: "trash",
                    title: "삭제한 기록 복원하거나 영구 삭제하기",
                    body: "삭제한 기록은 바로 지워지지 않고 휴지통으로 이동합니다. 설정의 데이터 관리에서 ‘휴지통 열기’를 선택한 뒤 필요한 기록을 복원하세요. 기록별로 ‘영구 삭제’를 선택하거나 ‘휴지통 비우기’로 전체를 지울 수 있으며, 이 동작은 기록과 첨부를 모든 기기에서 완전히 제거하고 되돌릴 수 없습니다."
                ),
            ]
        ),
        AppUsageGuideSection(
            id: "sync",
            title: "동기화",
            systemImage: "icloud",
            items: [
                AppUsageGuideItem(
                    id: "apple-and-icloud",
                    title: "Apple 로그인과 iCloud",
                    body: "Apple 로그인은 앱 접근에 사용하고 기록 동기화는 기기의 시스템 iCloud 개인 데이터베이스를 사용합니다. Mac과 iPhone에서 같은 Apple 사용자와 iCloud 계정을 사용하세요."
                ),
                AppUsageGuideItem(
                    id: "local-first",
                    title: "연결이 없어도 기록하기",
                    body: "기록은 먼저 기기에 저장되므로 오프라인에서도 작성하고 편집할 수 있습니다. 연결이 돌아오면 동기화되며 현재 상태는 설정의 동기화 섹션에서 확인하거나 새로고침할 수 있습니다."
                ),
            ]
        ),
        AppUsageGuideSection(
            id: "security",
            title: "보안",
            systemImage: "lock.shield",
            items: [
                AppUsageGuideItem(
                    id: "app-lock",
                    title: "앱 잠금 사용하기",
                    body: "설정의 ‘앱 잠금’에서 기기별 비밀번호와 자동 잠금 시간을 정하세요. 지원되는 기기에서는 Face ID 또는 Touch ID로 잠금을 해제할 수 있습니다."
                ),
                AppUsageGuideItem(
                    id: "app-lock-boundary",
                    title: "앱 잠금의 보호 범위",
                    body: "앱 잠금은 화면 접근과 앱 전환기 미리보기를 보호합니다. 데이터베이스나 CloudKit 기록 자체를 별도 비밀번호로 종단 간 암호화하는 기능은 아닙니다."
                ),
            ]
        ),
    ]

    static let macOSDataManagementSection = AppUsageGuideSection(
        id: "mac-data-management",
        title: "Mac 데이터 관리",
        systemImage: "externaldrive",
        items: [
            AppUsageGuideItem(
                id: "day-one-import",
                title: "Day One 기록 가져오기",
                body: "Day One에서 JSON 형식의 ZIP을 내보낸 뒤 Mac 설정의 ‘Day One 가져오기…’를 선택하세요. 분석 결과와 분류 제안을 확인한 다음 가져오기를 실행합니다."
            ),
            AppUsageGuideItem(
                id: "backup",
                title: "전체 백업 내보내기",
                body: "Mac 설정의 백업 및 복원에서 ‘전체 백업 내보내기…’를 선택하세요. 생성된 백업 파일에는 기록, 수정 이력, 휴지통 정보, 분류 규칙과 첨부가 포함됩니다."
            ),
            AppUsageGuideItem(
                id: "restore",
                title: "백업 복원하기",
                body: "‘백업에서 복원…’을 선택하고 병합 또는 현재 데이터 교체 방식을 고르세요. 교체 복원은 현재 상태의 안전 백업을 먼저 만든 뒤 진행합니다."
            ),
        ]
    )

    static func sections(for platform: AppUsageGuidePlatform) -> [AppUsageGuideSection] {
        switch platform {
        case .iOS:
            commonSections
        case .macOS:
            commonSections + [macOSDataManagementSection]
        }
    }

    static var currentSections: [AppUsageGuideSection] {
        #if os(macOS)
        sections(for: .macOS)
        #else
        sections(for: .iOS)
        #endif
    }
}

struct AppUsageGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("앱 사용법", systemImage: "questionmark.circle.fill")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("기록 작성부터 동기화와 데이터 관리까지 필요한 기능을 확인하세요.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            ForEach(AppUsageGuideContent.currentSections) { section in
                Section {
                    ForEach(section.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(item.body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("앱 사용법")
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Label("설정으로 돌아가기", systemImage: "chevron.left")
                }
            }
        }
        #endif
    }
}
