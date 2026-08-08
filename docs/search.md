# 검색 구현 결정

검색 인덱스는 Apple SDK에 포함된 SQLite3와 FTS5를 직접 사용한다.

- 외부 package 의존성이 없다.
- SQLite는 public domain이다.
- `trigram` tokenizer를 우선 사용해 한국어 부분 문자열을 찾는다.
- 현재 OS SQLite가 trigram을 제공하지 않으면 `unicode61` FTS table로 생성한다.
- 두 글자 이하 검색은 `LIKE` fallback을 사용한다.
- 검색 데이터는 derived data이며 CloudKit이나 백업에 넣지 않는다.
- 로컬 저장과 원격 history가 entry ID를 indexing queue에 넣는다.
- history token이 맞지 않거나 integrity check가 실패하면 canonical store에서 재구축한다.
