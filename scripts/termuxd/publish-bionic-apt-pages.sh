#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

packages_dir="${TERMUXD_BIONIC_OUTPUT_DIR:-${TERMUXD_OUTPUT_DIR}}"
filter_tmp_parent="${PAGES_TMPDIR:-${TERMUXD_REPO_ROOT}/.tmp-pages}"
mkdir -p "${filter_tmp_parent}"
filtered_dir="$(mktemp -d "${filter_tmp_parent%/}/bionic-filter.XXXXXX")"

cleanup() {
	rm -rf "${filtered_dir}"
}
trap cleanup EXIT

shopt -s nullglob
for deb in "${packages_dir}"/*.deb; do
	base="$(basename "${deb}")"
	case "${base}" in
		glibc_*.deb|glibc-*.deb|glibc32_*.deb|*-glibc_*.deb|*-glibc-static_*.deb)
			continue
			;;
	esac
	cp "${deb}" "${filtered_dir}/${base}"
done
shopt -u nullglob

APT_MERGE_EXISTING="${APT_MERGE_EXISTING:-true}" exec "${script_dir}/publish-apt-pages.sh" \
	"${TERMUXD_REPO_ROOT}" \
	"${filtered_dir}" \
	"${PAGES_REPO_DIR:-apt/bionic}"
