#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

packages_dir="${TERMUXD_GLIBC_OUTPUT_DIR:-${TERMUXD_GLIBC_PACKAGES_WORK_DIR}/output}"
filter_tmp_parent="${PAGES_TMPDIR:-${TERMUXD_REPO_ROOT}/.tmp-pages}"
mkdir -p "${filter_tmp_parent}"
filtered_dir="$(mktemp -d "${filter_tmp_parent%/}/glibc-filter.XXXXXX")"

cleanup() {
	rm -rf "${filtered_dir}"
}
trap cleanup EXIT

shopt -s nullglob
for deb in "${packages_dir}"/*.deb; do
	base="$(basename "${deb}")"
	case "${base}" in
		glibc-static_*.deb|*-glibc-static_*.deb|resolv-conf-glibc_*.deb)
			continue
			;;
		glibc_*.deb|glibc32_*.deb|glibc-runner_*.deb|*-glibc_*.deb|*-glibc32_*.deb)
			cp "${deb}" "${filtered_dir}/${base}"
			;;
		*)
			continue
			;;
	esac
done
shopt -u nullglob

APT_MERGE_EXISTING="${APT_MERGE_EXISTING:-true}" exec "${script_dir}/publish-apt-pages.sh" \
	"${TERMUXD_REPO_ROOT}" \
	"${filtered_dir}" \
	"${PAGES_REPO_DIR:-apt/glibc}"
