#!/usr/bin/env bash
# 문서를 업로드하고 처리 결과까지 확인한다.
#   사용법: ./scripts/upload-sample.sh <파일경로>
#
# 공개 API 는 API 키를 요구한다. 키가 없으면 내부 경로로 하나 발급받는다.
#   OWNER_ID     소유자 (기본: demo)
#   API_KEY      이미 가진 키가 있으면 지정
#   INTERNAL_TOKEN  키 발급에 필요한 내부 토큰 (기본: 개발용 기본값)
set -euo pipefail

BACKEND="${BACKEND_BASE_URL:-http://localhost:8080}"
FILE="${1:?업로드할 파일 경로를 넘겨주세요 (예: ./scripts/upload-sample.sh scan.png)}"
OWNER="${OWNER_ID:-demo}"
TOKEN="${INTERNAL_TOKEN:-local-dev-only-token}"

extract() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

API_KEY="${API_KEY:-}"
if [ -z "${API_KEY}" ]; then
  echo "▶ API 키 발급 (소유자: ${OWNER})"
  API_KEY=$(curl -sS -X POST "${BACKEND}/internal/v1/api-keys" \
    -H "X-Internal-Token: ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"ownerId\":\"${OWNER}\",\"label\":\"upload-sample.sh\"}" | extract key)
  if [ -z "${API_KEY}" ]; then
    echo "✖ 키 발급에 실패했습니다. backend 가 떠 있고 INTERNAL_TOKEN 이 맞는지 확인하세요." >&2
    exit 1
  fi
  echo "   ${API_KEY:0:12}...  (평문은 발급 응답에서만 볼 수 있다)"
  echo
fi

echo "▶ 업로드: ${FILE}"
RESPONSE=$(curl -sS -H "X-API-Key: ${API_KEY}" -F "file=@${FILE}" "${BACKEND}/api/v1/documents")
echo "${RESPONSE}"

DOC_ID=$(echo "${RESPONSE}" | extract id)
if [ -z "${DOC_ID}" ]; then
  echo "✖ 문서 ID를 읽지 못했습니다" >&2
  exit 1
fi

echo
echo "▶ OCR 처리 접수 (평소에는 스케줄러가 호출한다. 내부 API 는 소유자를 가리지 않는다)"
curl -sS -X POST -H "X-Internal-Token: ${TOKEN}" "${BACKEND}/internal/v1/ocr/process-pending"

echo
echo
echo "▶ 상태: ${DOC_ID}"
curl -sS -H "X-API-Key: ${API_KEY}" "${BACKEND}/api/v1/documents/${DOC_ID}"

echo
echo
echo "▶ 추출 텍스트"
curl -sS -H "X-API-Key: ${API_KEY}" "${BACKEND}/api/v1/documents/${DOC_ID}/text"
echo
