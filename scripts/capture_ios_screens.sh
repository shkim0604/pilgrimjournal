#!/bin/sh
set -eu

# iPhone 시뮬레이터에서 Light·Dark, 기본·접근성 글자 크기와 Increase Contrast
# 조합의 screenshot을 남긴다. PILGRIM_VISUAL_TESTING=1로 실행하므로 인증을
# 우회하고 메모리 저장소를 사용해 실제 사용자 데이터와 분리된다.
#
#   scripts/capture_ios_screens.sh launch      # 실행 직후 화면을 매트릭스로 촬영
#   scripts/capture_ios_screens.sh hold <이름>  # 직접 이동한 화면을 매트릭스로 촬영
#
# `hold`는 앱을 한 번만 띄운 뒤 원하는 화면으로 이동할 시간을 준다. Enter를
# 누르면 appearance와 글자 크기만 바꿔 가며 같은 화면을 연속 촬영한다.

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
device=${PILGRIM_SIM_DEVICE:-iPhone 17}
bundle_id=com.dhouse.PilgrimJournal
derived_data="$repo_root/.derived-data-screens"
output_dir="$repo_root/docs/visual-regression/ios"
mode=${1:-launch}
screen_name=${2:-home}

log() { printf '%s\n' "$*" >&2; }

build_and_install() {
  log "iOS Simulator DEBUG 빌드 중…"
  xcodebuild \
    -project "$repo_root/PilgrimJournal/PilgrimJournal.xcodeproj" \
    -scheme PilgrimJournalApp \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=$device" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

  app_path="$derived_data/Build/Products/Debug-iphonesimulator/PilgrimJournal.app"
  [ -d "$app_path" ] || { log "빌드 산출물을 찾지 못했습니다: $app_path"; exit 1; }

  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
  xcrun simctl install "$device" "$app_path"
}

launch_app() {
  SIMCTL_CHILD_PILGRIM_VISUAL_TESTING=1 \
    xcrun simctl launch --terminate-running-process "$device" "$bundle_id" >/dev/null
  # 첫 화면 구성과 애니메이션이 끝날 때까지 기다린다.
  sleep 3
}

# 사용법: capture <appearance> <content_size> <contrast> <파일 접미사>
capture() {
  xcrun simctl ui "$device" appearance "$1" >/dev/null
  xcrun simctl ui "$device" content_size "$2" >/dev/null
  xcrun simctl ui "$device" increase_contrast "$3" >/dev/null
  sleep 2
  target="$output_dir/${screen_name}-$4.png"
  xcrun simctl io "$device" screenshot --type=png "$target" >/dev/null
  log "  저장: ${target#"$repo_root"/}"
}

capture_matrix() {
  capture light medium disabled light
  capture dark medium disabled dark
  capture light accessibility-extra-extra-extra-large disabled light-axxxl
  capture dark accessibility-extra-extra-extra-large disabled dark-axxxl
  capture light medium enabled light-high-contrast
  capture dark medium enabled dark-high-contrast
  # 다음 실행에 영향을 주지 않도록 기본 상태로 되돌린다.
  xcrun simctl ui "$device" appearance light >/dev/null
  xcrun simctl ui "$device" content_size medium >/dev/null
  xcrun simctl ui "$device" increase_contrast disabled >/dev/null
}

mkdir -p "$output_dir"
build_and_install

case "$mode" in
launch)
  log "실행 직후 화면을 촬영합니다."
  launch_app
  capture_matrix
  ;;
hold)
  launch_app
  log ""
  log "시뮬레이터에서 '$screen_name' 화면으로 이동한 뒤 Enter를 누르세요."
  read -r _
  capture_matrix
  ;;
*)
  log "사용법: $0 [launch|hold] [화면 이름]"
  exit 1
  ;;
esac

log "완료: ${output_dir#"$repo_root"/}"
