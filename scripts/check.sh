#!/bin/sh
set -eu

swift format lint --strict --recursive Sources Tests scripts/make_anonymous_dayone_export.swift
# The group-server contract package (server/PilgrimAPI) uses the same .swift-format config.
swift format lint --strict --recursive \
  server/PilgrimAPI/Package.swift server/PilgrimAPI/Sources server/PilgrimAPI/Tests
swift build
swift test
swift test --package-path server/PilgrimAPI
swift run JournalChecks "$@"

# The admin console (web/admin) reads a committed schema/architecture snapshot; fail when a model
# or Package.swift changed without regenerating it.
snapshot_tmp=$(mktemp -d)
trap 'rm -rf "$snapshot_tmp"' EXIT
./scripts/admin-snapshot.sh "$snapshot_tmp" >/dev/null
for file in schema.json architecture.json; do
  if ! cmp -s "web/admin/snapshot/$file" "$snapshot_tmp/$file"; then
    echo "관리 콘솔 스냅샷이 오래됐습니다(web/admin/snapshot/$file). scripts/admin-snapshot.sh를 실행하고 커밋하세요." >&2
    exit 1
  fi
done

if find . -path './.build' -prune -o -path './web/admin/node_modules' -prune -o -type f -name '*.zip' -print | grep -q .; then
  echo "개인 ZIP으로 보이는 파일이 저장소에 있습니다." >&2
  exit 1
fi

if git ls-files | grep -E '(DayOne|day-one|일기).*(zip|json)$' >/dev/null 2>&1; then
  echo "개인 Day One export로 보이는 파일이 Git에 포함되어 있습니다." >&2
  exit 1
fi

echo "Pilgrim Journal 검증 완료"
