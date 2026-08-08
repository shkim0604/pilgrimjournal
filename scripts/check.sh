#!/bin/sh
set -eu

swift build
swift test
swift run JournalChecks "$@"

if find . -path './.build' -prune -o -type f -name '*.zip' -print | grep -q .; then
  echo "개인 ZIP으로 보이는 파일이 저장소에 있습니다." >&2
  exit 1
fi

if git ls-files | grep -E '(DayOne|day-one|일기).*(zip|json)$' >/dev/null 2>&1; then
  echo "개인 Day One export로 보이는 파일이 Git에 포함되어 있습니다." >&2
  exit 1
fi

echo "Pilgrim Journal 검증 완료"
