#!/usr/bin/env bash
# 문서를 업로드하고 처리 결과까지 확인한다.
#   사용법: ./scripts/upload-sample.sh <파일경로>
set -euo pipefail

BACKEND="${BACKEND_BASE_URL:-http://localhost:8080}"
FILE="${1:?업로드할 파일 경로를 넘겨주세요 (예: ./scripts/upload-sample.sh scan.png)}"

echo "▶ 업로드: ${FILE}"
RESPONSE=$(curl -sS -F "file=@${FILE}" "${BACKEND}/api/v1/documents")
echo "${RESPONSE}"

DOC_ID=$(echo "${RESPONSE}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -z "${DOC_ID}" ]; then
  echo "✖ 문서 ID를 읽지 못했습니다" >&2
  exit 1
fi

echo
echo "▶ OCR 처리 요청 (평소에는 스케줄러가 호출한다)"
curl -sS -X POST "${BACKEND}/internal/v1/ocr/process-pending"

echo
echo
echo "▶ 상태: ${DOC_ID}"
curl -sS "${BACKEND}/api/v1/documents/${DOC_ID}"

echo
echo
echo "▶ 추출 텍스트"
curl -sS "${BACKEND}/api/v1/documents/${DOC_ID}/text"
echo
