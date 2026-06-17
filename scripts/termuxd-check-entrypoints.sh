#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
termuxd_dir="${repo_root}/scripts/termuxd"

require_file() {
	local path="$1"

	if [[ ! -f "${path}" ]]; then
		echo "missing termuxd entrypoint: ${path}" >&2
		exit 1
	fi
}

require_equal() {
	local actual="$1"
	local expected="$2"
	local label="$3"

	if [[ "${actual}" != "${expected}" ]]; then
		echo "${label}: expected '${expected}', got '${actual}'" >&2
		exit 1
	fi
}

for script_name in \
	config.sh \
	build-bionic-packages.sh \
	build-glibc-packages.sh \
	package-runtime.sh \
	publish-apt-pages.sh \
	publish-bionic-apt-pages.sh \
	publish-glibc-apt-pages.sh \
	seed-glibc-apt-build-prefix.sh; do
	require_file "${termuxd_dir}/${script_name}"
done

# shellcheck source=scripts/termuxd/config.sh
source "${termuxd_dir}/config.sh"

require_equal "${TERMUXD_PREFIX_PATH}" "/data/local/tmp/termuxd/runtime/usr" "TERMUXD_PREFIX_PATH"
require_equal "${TERMUXD_GLIBC_PREFIX_PATH}" "/data/local/tmp/termuxd/runtime/usr/glibc" "TERMUXD_GLIBC_PREFIX_PATH"
require_equal "${TERMUXD_BIONIC_APT_REPO_URL}" "https://ykmmj.github.io/termuxd-packages-repo/apt/bionic" "TERMUXD_BIONIC_APT_REPO_URL"
require_equal "${TERMUXD_GLIBC_APT_REPO_URL}" "https://ykmmj.github.io/termuxd-packages-repo/apt/glibc" "TERMUXD_GLIBC_APT_REPO_URL"
require_equal "${TERMUXD_BIONIC_ROOT_PACKAGES}" "apt bash" "TERMUXD_BIONIC_ROOT_PACKAGES"
require_equal "${TERMUXD_BIONIC_BUILD_PACKAGES}" "apt bash" "TERMUXD_BIONIC_BUILD_PACKAGES"
require_equal "${TERMUXD_GLIBC_PACKAGES}" "glibc-runner" "TERMUXD_GLIBC_PACKAGES"
require_equal "${TERMUXD_GLIBC_SEED_PACKAGES}" "linux-api-headers-glibc glibc" "TERMUXD_GLIBC_SEED_PACKAGES"
require_equal "${TERMUXD_USE_DOCKER}" "true" "TERMUXD_USE_DOCKER"
require_equal "${TERMUXD_REBUILD_ROOT_PACKAGES}" "true" "TERMUXD_REBUILD_ROOT_PACKAGES"

for build_script in build-bionic-packages.sh build-glibc-packages.sh; do
	grep -q 'TERMUXD_INVOCATION_DIR="${PWD}"' "${termuxd_dir}/${build_script}" || {
		echo "${build_script} must keep build logs in the invocation directory" >&2
		exit 1
	}
	grep -q 'tee -a' "${termuxd_dir}/${build_script}" || {
		echo "${build_script} must tee build output to a log file" >&2
		exit 1
	}
	grep -q '/data/data/.built-packages' "${termuxd_dir}/${build_script}" || {
		echo "${build_script} must clear stale built markers before root package builds" >&2
		exit 1
	}
done

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT
source_repo="${tmp_root}/source"
packages_dir="${tmp_root}/packages"
remote_repo="${tmp_root}/remote.git"
mkdir -p "${source_repo}" "${packages_dir}"

git -C "${source_repo}" init -q
git -C "${source_repo}" -c user.name=termuxd -c user.email=termuxd@example.invalid commit --allow-empty -q -m init
git -C "${source_repo}" init -q --bare "${remote_repo}"

make_fake_deb() {
	local output_dir="$1"
	local package_name="$2"
	local root="${tmp_root}/pkg-${package_name}"

	rm -rf "${root}"
	mkdir -p "${root}/DEBIAN" "${root}/data/local/tmp/termuxd/runtime/usr/share/${package_name}"
	cat > "${root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: 1.0
Architecture: aarch64
Maintainer: termuxd test <termuxd@example.invalid>
Description: fake ${package_name}
EOF
	printf '%s\n' "${package_name}" > "${root}/data/local/tmp/termuxd/runtime/usr/share/${package_name}/payload"
	dpkg-deb -b "${root}" "${output_dir}/${package_name}_1.0_aarch64.deb" >/dev/null
}

make_fake_deb "${packages_dir}" "bash"
make_fake_deb "${packages_dir}" "glibc"
make_fake_deb "${packages_dir}" "glibc-runner"
make_fake_deb "${packages_dir}" "attr-glibc"
make_fake_deb "${packages_dir}" "attr-glibc-static"

if "${termuxd_dir}/publish-apt-pages.sh" "${source_repo}" "${packages_dir}" "apt/bionic" >/dev/null 2>"${tmp_root}/publish.log"; then
	echo "publish-apt-pages.sh must require explicit PAGES_REMOTE_URL" >&2
	exit 1
fi

grep -q "PAGES_REMOTE_URL" "${tmp_root}/publish.log" || {
	echo "publish-apt-pages.sh failure should mention PAGES_REMOTE_URL" >&2
	cat "${tmp_root}/publish.log" >&2
	exit 1
}

PAGES_REMOTE_URL="${remote_repo}" \
PAGES_TMPDIR="${tmp_root}/tmp-pages" \
TERMUXD_BIONIC_OUTPUT_DIR="${packages_dir}" \
	"${termuxd_dir}/publish-bionic-apt-pages.sh" >/dev/null

PAGES_REMOTE_URL="${remote_repo}" \
PAGES_TMPDIR="${tmp_root}/tmp-pages" \
TERMUXD_GLIBC_OUTPUT_DIR="${packages_dir}" \
	"${termuxd_dir}/publish-glibc-apt-pages.sh" >/dev/null

published="${tmp_root}/published"
git clone --branch gh-pages --single-branch "${remote_repo}" "${published}" >/dev/null 2>&1

bionic_index="${published}/apt/bionic/dists/stable/main/binary-aarch64/Packages"
glibc_index="${published}/apt/glibc/dists/stable/main/binary-aarch64/Packages"
[[ -f "${bionic_index}" ]] || { echo "missing bionic Packages index" >&2; exit 1; }
[[ -f "${glibc_index}" ]] || { echo "missing glibc Packages index" >&2; exit 1; }

grep -q '^Package: bash$' "${bionic_index}" || {
	echo "expected bash in bionic repo" >&2
	exit 1
}
if grep -q '^Package: glibc$' "${bionic_index}" || grep -q '^Package: attr-glibc$' "${bionic_index}"; then
	echo "glibc packages must be filtered from bionic repo" >&2
	exit 1
fi

grep -q '^Package: glibc-runner$' "${glibc_index}" || {
	echo "expected glibc-runner in glibc repo" >&2
	exit 1
}
grep -q '^Package: attr-glibc$' "${glibc_index}" || {
	echo "expected attr-glibc in glibc repo" >&2
	exit 1
}
if grep -q '^Package: attr-glibc-static$' "${glibc_index}"; then
	echo "static glibc packages must be filtered from glibc repo" >&2
	exit 1
fi
if grep -q '^Package: bash$' "${glibc_index}"; then
	echo "bionic packages must be filtered from glibc repo" >&2
	exit 1
fi

echo "termuxd entrypoints ok"
