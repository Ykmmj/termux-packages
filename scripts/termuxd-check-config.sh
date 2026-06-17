#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
	jq() {
		local raw_output=false
		if [[ "${1:-}" == "--raw-output" || "${1:-}" == "-r" ]]; then
			raw_output=true
			shift
		fi
		local query="$1"
		local json_file="$2"

		python3 - "${query}" "${json_file}" <<'PY'
import json
import sys

query = sys.argv[1]
path = sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

repos = {key: value for key, value in data.items() if key != "pkg_format"}
if query == "del(.pkg_format) | keys | .[]":
    for key in repos:
        print(key)
elif query == "del(.pkg_format) | .[] | .url":
    for value in repos.values():
        print(value["url"])
elif query == "del(.pkg_format) | .[] | .distribution":
    for value in repos.values():
        print(value["distribution"])
elif query == "del(.pkg_format) | .[] | .component":
    for value in repos.values():
        print(value["component"])
else:
    raise SystemExit(f"unsupported jq fallback query: {query}")
PY
	}
fi

require_equal() {
	local actual="$1"
	local expected="$2"
	local label="$3"

	if [[ "${actual}" != "${expected}" ]]; then
		echo "${label}: expected '${expected}', got '${actual}'" >&2
		exit 1
	fi
}

source "${repo_root}/scripts/properties.sh"

require_equal "${TERMUX_APP__DATA_DIR}" "/data/local/tmp/termuxd" "TERMUX_APP__DATA_DIR"
require_equal "${TERMUX__ROOTFS}" "/data/local/tmp/termuxd/runtime" "TERMUX__ROOTFS"
require_equal "${TERMUX__PREFIX}" "/data/local/tmp/termuxd/runtime/usr" "TERMUX__PREFIX"
require_equal "${TERMUX__PREFIX_GLIBC}" "/data/local/tmp/termuxd/runtime/usr/glibc" "TERMUX__PREFIX_GLIBC"
require_equal "${TERMUX__CACHE_DIR}" "/data/local/tmp/termuxd/cache" "TERMUX__CACHE_DIR"
require_equal "${TERMUX_REPO_APP__PACKAGE_NAME}" "${TERMUX_APP__PACKAGE_NAME}" "TERMUX_REPO_APP__PACKAGE_NAME"
require_equal "${TERMUX_REPO_APP__DATA_DIR}" "${TERMUX_APP__DATA_DIR}" "TERMUX_REPO_APP__DATA_DIR"
require_equal "${TERMUX_REPO__ROOTFS}" "${TERMUX__ROOTFS}" "TERMUX_REPO__ROOTFS"
require_equal "${TERMUX_REPO__HOME}" "/data/local/tmp/termuxd/runtime/home" "TERMUX_REPO__HOME"
require_equal "${TERMUX_REPO__PREFIX}" "${TERMUX__PREFIX}" "TERMUX_REPO__PREFIX"
require_equal "${CGCT_DEFAULT_PREFIX}" "/data/data/com.termux/files/usr/glibc" "CGCT_DEFAULT_PREFIX"
require_equal "${CGCT_DIR}" "/data/data/com.termux/cgct" "CGCT_DIR"
require_equal "${TERMUX_REPO_URL[0]}" "https://ykmmj.github.io/termuxd-packages/apt/bionic" "TERMUX_REPO_URL[0]"
require_equal "${TERMUX_REPO_DISTRIBUTION[0]}" "stable" "TERMUX_REPO_DISTRIBUTION[0]"
require_equal "${TERMUX_REPO_COMPONENT[0]}" "main" "TERMUX_REPO_COMPONENT[0]"

echo "termuxd bionic config ok"
