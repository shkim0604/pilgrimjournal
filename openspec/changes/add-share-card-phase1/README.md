# add-share-card-phase1

기록 하나를 기도제목·독후감·간증 나눔 카드로 만들어 시스템 공유 시트로 보낸다 — 서버와
그룹 없이, 초안은 기기 안의 Apple 온디바이스 모델로 (`docs/roadmap.md` 공유 카드의 1단계)

- `proposal.md` — 왜, 무엇을, 영향 범위
- `design.md` — 사용자 흐름, 모듈 배치, 추출 파이프라인, 가용성 분기, 렌더링·공유,
  현지화, 테스트, 실기기 확인, 2단계로 이어지는 것, **주인에게 묻는 열린 질문**
- `specs/share-card/spec.md` — 요구사항과 시나리오
- `specs/in-app-usage-guide/spec.md` — 앱 사용법에 나눔 카드 안내 추가
- `tasks.md` — 구현 순서
- `groups-cloudkit.md` — (2단계 검토안) 그룹을 자체 백엔드 대신 CloudKit으로: CKShare vs public DB,
  로드맵 요구사항 대응표, 주인이 정할 것, 계정 삭제. 1단계 구현 범위가 아니다.
