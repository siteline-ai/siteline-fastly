#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
ZIP_PATH="${LAMBDA_ZIP_PATH:-${DIST_DIR}/lambda-edge.zip}"
ZIP_DIR="$(dirname "${ZIP_PATH}")"
INCLUDE_ENV_FILE="${INCLUDE_ENV_FILE:-false}"
ENV_FILE_PATH="${ENV_FILE_PATH:-${ROOT_DIR}/.env}"

if [[ ! -f "${DIST_DIR}/index.js" ]]; then
  echo "Build output not found at ${DIST_DIR}/index.js. Run npm run build first." >&2
  exit 1
fi

mkdir -p "${ZIP_DIR}"
rm -f "${ZIP_PATH}"

files=("index.js")
if [[ -f "${DIST_DIR}/index.js.map" ]]; then
  files+=("index.js.map")
fi

copied_env_file=false
if [[ "${INCLUDE_ENV_FILE}" == "true" && -f "${ENV_FILE_PATH}" ]]; then
  cp "${ENV_FILE_PATH}" "${DIST_DIR}/.env"
  files+=(".env")
  copied_env_file=true
elif [[ "${INCLUDE_ENV_FILE}" == "true" ]]; then
  echo "No .env file found at ${ENV_FILE_PATH}; runtime will use defaults." >&2
fi

(
  cd "${DIST_DIR}"
  zip -q -r "${ZIP_PATH}" "${files[@]}"
)

if [[ "${copied_env_file}" == "true" ]]; then
  rm -f "${DIST_DIR}/.env"
fi

echo "S3 log processor Lambda package created: ${ZIP_PATH}"
