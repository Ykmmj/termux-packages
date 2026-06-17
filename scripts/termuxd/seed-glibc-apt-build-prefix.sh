#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

: "${SEED_ROOT_DIR:=/}"
: "${TERMUX_BUILT_PACKAGES_DIRECTORY:=/data/data/.built-packages}"
: "${TERMUXD_SEED_CACHE_DIR:=${TMPDIR:-/tmp}/termuxd-glibc-seed}"

if (($# == 0)); then
	read -r -a packages <<< "${TERMUXD_GLIBC_SEED_PACKAGES}"
else
	packages=("$@")
fi

download_to() {
	local url="$1"
	local output="$2"
	case "${url}" in
		file://*) cp "${url#file://}" "${output}" ;;
		http://*|https://*) curl -fsSL --retry 3 --connect-timeout 20 -o "${output}" "${url}" ;;
		*) cp "${url}" "${output}" ;;
	esac
}

repo_file_url() {
	local filename="$1"
	case "${filename}" in
		file://*|http://*|https://*) printf '%s\n' "${filename}" ;;
		*) printf '%s/%s\n' "${TERMUXD_GLIBC_APT_REPO_URL%/}" "${filename#./}" ;;
	esac
}

read_package_record() {
	local packages_file="$1"
	local wanted_package="$2"

	awk -v wanted_package="${wanted_package}" -v wanted_arch="${TERMUXD_RUNTIME_ABI}" '
		BEGIN { RS = ""; FS = "\n"; found = 0; }
		{
			package_name = ""; version = ""; arch = ""; filename = ""; sha256 = "";
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^Package: /) package_name = substr($i, 10);
				else if ($i ~ /^Version: /) version = substr($i, 10);
				else if ($i ~ /^Architecture: /) arch = substr($i, 15);
				else if ($i ~ /^Filename: /) filename = substr($i, 11);
				else if ($i ~ /^SHA256: /) sha256 = substr($i, 9);
			}
			if (package_name == wanted_package && (arch == wanted_arch || arch == "all")) {
				printf "%s\t%s\t%s\t%s\t%s\n", package_name, version, arch, filename, sha256;
				found = 1;
				exit;
			}
		}
		END { if (!found) exit 1; }
	' "${packages_file}"
}

verify_sha256() {
	local file="$1"
	local expected="$2"

	if [[ -z "${expected}" ]]; then
		return
	fi

	local actual
	actual="$(sha256sum "${file}" | awk '{print $1}')"
	if [[ "${actual}" != "${expected}" ]]; then
		echo "sha256 mismatch for ${file}: expected ${expected}, got ${actual}" >&2
		exit 1
	fi
}

extract_deb() {
	local deb_path="$1"

	if [[ "${SEED_ROOT_DIR}" == "/" ]]; then
		local stage_dir
		stage_dir="$(mktemp -d "${TERMUXD_SEED_CACHE_DIR%/}/extract.XXXXXX")"
		dpkg-deb -x "${deb_path}" "${stage_dir}"
		cp -R -P "${stage_dir}/." "${SEED_ROOT_DIR}"
		rm -rf "${stage_dir}"
	else
		dpkg-deb -x "${deb_path}" "${SEED_ROOT_DIR}"
	fi
}

mkdir -p "${TERMUXD_SEED_CACHE_DIR}" "${SEED_ROOT_DIR}" "${TERMUX_BUILT_PACKAGES_DIRECTORY}"
packages_index="$(mktemp "${TERMUXD_SEED_CACHE_DIR%/}/Packages.XXXXXX")"
packages_url="${TERMUXD_GLIBC_APT_REPO_URL%/}/dists/${TERMUXD_GLIBC_APT_REPO_DISTRIBUTION}/${TERMUXD_GLIBC_APT_REPO_COMPONENT}/binary-${TERMUXD_RUNTIME_ABI}/Packages"
download_to "${packages_url}" "${packages_index}"

for package_name in "${packages[@]}"; do
	record="$(read_package_record "${packages_index}" "${package_name}")" || {
		echo "package not found in ${packages_url}: ${package_name} (${TERMUXD_RUNTIME_ABI})" >&2
		exit 1
	}

	IFS=$'\t' read -r resolved_package version arch filename sha256 <<< "${record}"
	deb_path="${TERMUXD_SEED_CACHE_DIR%/}/${resolved_package}_${version}_${arch}.deb"
	download_to "$(repo_file_url "${filename}")" "${deb_path}"
	verify_sha256 "${deb_path}" "${sha256}"
	extract_deb "${deb_path}"
	printf '%s\n' "${version}" > "${TERMUX_BUILT_PACKAGES_DIRECTORY}/${resolved_package}"
	printf 'seeded %s %s from %s\n' "${resolved_package}" "${version}" "${filename}"
done
