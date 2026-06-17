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
	init-apt-pages.sh \
	package-runtime.sh \
	publish-apt-pages.sh \
	publish-bionic-apt-pages.sh \
	publish-glibc-apt-pages.sh \
	seed-glibc-apt-build-prefix.sh; do
	require_file "${termuxd_dir}/${script_name}"
done

# shellcheck source=scripts/termuxd/config.sh
source "${termuxd_dir}/config.sh"
# shellcheck source=scripts/utils/termux/package/termux_package.sh
source "${repo_root}/scripts/utils/termux/package/termux_package.sh"

require_equal "${TERMUXD_PREFIX_PATH}" "/data/local/tmp/termuxd/runtime/usr" "TERMUXD_PREFIX_PATH"
require_equal "${TERMUXD_GLIBC_PREFIX_PATH}" "/data/local/tmp/termuxd/runtime/usr/glibc" "TERMUXD_GLIBC_PREFIX_PATH"
require_equal "${TERMUXD_BIONIC_APT_REPO_URL}" "https://ykmmj.github.io/termuxd-packages-repo/apt/bionic" "TERMUXD_BIONIC_APT_REPO_URL"
require_equal "${TERMUXD_GLIBC_APT_REPO_URL}" "https://ykmmj.github.io/termuxd-packages-repo/apt/glibc" "TERMUXD_GLIBC_APT_REPO_URL"
require_equal "${TERMUXD_BIONIC_ROOT_PACKAGES}" "apt bash" "TERMUXD_BIONIC_ROOT_PACKAGES"
require_equal "${TERMUXD_BIONIC_BUILD_PACKAGES}" "apt bash" "TERMUXD_BIONIC_BUILD_PACKAGES"
require_equal "${TERMUXD_MINIMAL_BASH}" "true" "TERMUXD_MINIMAL_BASH"
require_equal "${TERMUXD_GLIBC_PACKAGES}" "glibc-runner" "TERMUXD_GLIBC_PACKAGES"
require_equal "${TERMUXD_GLIBC_SEED_PACKAGES}" "linux-api-headers-glibc glibc" "TERMUXD_GLIBC_SEED_PACKAGES"
require_equal "${TERMUXD_BUILD_PACKAGE_MODE}" "auto" "TERMUXD_BUILD_PACKAGE_MODE"
require_equal "${TERMUXD_GLIBC_SEED_MODE}" "auto" "TERMUXD_GLIBC_SEED_MODE"
require_equal "${TERMUXD_BUILD_JOBS}" "4" "TERMUXD_BUILD_JOBS"
require_equal "${TERMUXD_USE_DOCKER}" "true" "TERMUXD_USE_DOCKER"
require_equal "${TERMUXD_REBUILD_ROOT_PACKAGES}" "true" "TERMUXD_REBUILD_ROOT_PACKAGES"
require_equal "${TERMUXD_GLIBC_BUILDER_IMAGE_NAME}" "ghcr.io/termux/package-builder-cgct" "TERMUXD_GLIBC_BUILDER_IMAGE_NAME"
require_equal "${TERMUXD_RESET_GLIBC_CONTAINER}" "false" "TERMUXD_RESET_GLIBC_CONTAINER"

require_equal \
	"$(termux_package__add_prefix_glibc_to_package_list 'glibc (= 2.42)')" \
	"glibc (= 2.42)" \
	"glibc versioned dependency prefixing"

for build_script in build-bionic-packages.sh build-glibc-packages.sh; do
	grep -q 'TERMUXD_LOG_DIR="${TERMUXD_LOG_DIR:-${TERMUXD_INVOCATION_DIR}/log}"' "${termuxd_dir}/${build_script}" || {
		echo "${build_script} must keep build logs in the invocation log directory" >&2
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

grep -q 'CGCT_APP_PREFIX="${TERMUXD_GLIBC_PREFIX_PATH}"' "${termuxd_dir}/build-glibc-packages.sh" || {
	echo "build-glibc-packages.sh must pass the termuxd glibc prefix into builds" >&2
	exit 1
}
grep -q 'TERMUX_BUILDER_IMAGE_NAME="${TERMUXD_GLIBC_BUILDER_IMAGE_NAME}"' "${termuxd_dir}/build-glibc-packages.sh" || {
	echo "build-glibc-packages.sh must use the termuxd CGCT builder image" >&2
	exit 1
}
grep -q 'TERMUXD_RESET_GLIBC_CONTAINER' "${termuxd_dir}/build-glibc-packages.sh" || {
	echo "build-glibc-packages.sh must expose an explicit glibc container reset switch" >&2
	exit 1
}
grep -q 'Refreshing glibc workdir in place' "${termuxd_dir}/build-glibc-packages.sh" || {
	echo "build-glibc-packages.sh must preserve the glibc workdir mount root when reusing containers" >&2
	exit 1
}
if grep -q 'rm -rf "${TERMUXD_GLIBC_PACKAGES_WORK_DIR}"' "${termuxd_dir}/build-glibc-packages.sh"; then
	echo "build-glibc-packages.sh must not delete the glibc workdir mount root" >&2
	exit 1
fi

grep -q 'TERMUXD_MINIMAL_BASH=' "${termuxd_dir}/build-bionic-packages.sh" || {
	echo "build-bionic-packages.sh must pass TERMUXD_MINIMAL_BASH into Docker" >&2
	exit 1
}

grep -q 'TERMUX_PKG_MASSAGE_PROCESSES' "${repo_root}/scripts/build/termux_step_massage.sh" || {
	echo "termux_step_massage.sh must not hard-code nproc for symbol checks" >&2
	exit 1
}

for pages_script in init-apt-pages.sh publish-apt-pages.sh; do
	grep -q 'GIT_TERMINAL_PROMPT=0' "${termuxd_dir}/${pages_script}" || {
		echo "${pages_script} must fail fast instead of hanging on Git authentication prompts" >&2
		exit 1
	}
done

grep -q 'etc/profile.d/00-termuxd.sh' "${termuxd_dir}/package-runtime.sh" || {
	echo "package-runtime.sh must install a termuxd profile environment" >&2
	exit 1
}
grep -q 'runtime/termuxd-shell' "${termuxd_dir}/package-runtime.sh" || {
	echo "package-runtime.sh must install a termuxd shell launcher" >&2
	exit 1
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT
source_repo="${tmp_root}/source"
packages_dir="${tmp_root}/packages"
remote_repo="${tmp_root}/remote.git"
mkdir -p "${source_repo}" "${packages_dir}"

empty_repo="${tmp_root}/empty-repo"
ready_repo="${tmp_root}/ready-repo"
mkdir -p "${empty_repo}" "${ready_repo}/dists/stable/main/binary-aarch64"
touch "${ready_repo}/dists/stable/Release"
cat > "${ready_repo}/dists/stable/main/binary-aarch64/Packages" <<'EOF'
Package: apt
Version: 1.0
Architecture: aarch64
Filename: pool/main/apt_1.0_aarch64.deb
EOF

resolved_args=()
termuxd_resolve_build_package_args "file://${ready_repo}" "stable" resolved_args
require_equal "${resolved_args[*]}" "-I" "auto build mode with available remote repo"

resolved_args=()
termuxd_resolve_build_package_args "file://${empty_repo}" "stable" resolved_args
require_equal "${resolved_args[*]}" "" "auto build mode with empty remote repo"

termuxd_should_seed_glibc_prefix "file://${ready_repo}" "stable" "main" "aarch64" || {
	echo "glibc seed should run when the remote Packages index is available" >&2
	exit 1
}

if termuxd_should_seed_glibc_prefix "file://${empty_repo}" "stable" "main" "aarch64"; then
	echo "glibc seed should skip when the remote Packages index is unavailable" >&2
	exit 1
fi

git -C "${source_repo}" init -q
git -C "${source_repo}" -c user.name=termuxd -c user.email=termuxd@example.invalid commit --allow-empty -q -m init
git -C "${source_repo}" init -q --bare "${remote_repo}"

PAGES_REMOTE_URL="${remote_repo}" \
PAGES_TMPDIR="${tmp_root}/tmp-pages" \
	"${termuxd_dir}/init-apt-pages.sh" >/dev/null

initialized="${tmp_root}/initialized"
git clone --branch gh-pages --single-branch "${remote_repo}" "${initialized}" >/dev/null 2>&1
for repo_path in apt/bionic apt/glibc; do
	[[ -f "${initialized}/${repo_path}/dists/stable/Release" ]] || {
		echo "missing initialized Release: ${repo_path}" >&2
		exit 1
	}
	empty_index="${initialized}/${repo_path}/dists/stable/main/binary-aarch64/Packages"
	[[ -f "${empty_index}" ]] || {
		echo "missing initialized Packages index: ${repo_path}" >&2
		exit 1
	}
	if grep -q '^Package: ' "${empty_index}"; then
		echo "initialized ${repo_path} should not contain package records" >&2
		exit 1
	fi
done

buildorder_root="${tmp_root}/buildorder"
mkdir -p "${buildorder_root}/gpkg/bash" "${buildorder_root}/gpkg/glibc-runner"
mkdir -p "${buildorder_root}/gpkg/openssl" "${buildorder_root}/packages/resolv-conf"
cat > "${buildorder_root}/gpkg/bash/build.sh" <<'EOF'
TERMUX_PKG_VERSION=1
EOF
cat > "${buildorder_root}/gpkg/glibc-runner/build.sh" <<'EOF'
TERMUX_PKG_DEPENDS="bash"
EOF
cat > "${buildorder_root}/gpkg/openssl/build.sh" <<'EOF'
TERMUX_PKG_DEPENDS="resolv-conf"
EOF
cat > "${buildorder_root}/packages/resolv-conf/build.sh" <<'EOF'
TERMUX_PKG_VERSION=1
EOF
buildorder_output="$(
	cd "${buildorder_root}"
	TERMUX_PACKAGE_LIBRARY=glibc \
	TERMUX_GLOBAL_LIBRARY=true \
	TERMUX_ARCH=aarch64 \
		"${repo_root}/scripts/buildorder.py" \
		gpkg/glibc-runner \
		gpkg
)"
grep -q '^bash-glibc' <<< "${buildorder_output}" || {
	echo "glibc buildorder must resolve bare bridge dependencies to glibc package names" >&2
	exit 1
}
buildorder_output="$(
	cd "${buildorder_root}"
	TERMUX_PACKAGE_LIBRARY=glibc \
	TERMUX_GLOBAL_LIBRARY=true \
	TERMUX_ARCH=aarch64 \
		"${repo_root}/scripts/buildorder.py" \
		gpkg/openssl \
		gpkg
)"
if grep -q 'resolv-conf' <<< "${buildorder_output}"; then
	echo "glibc buildorder must keep bionic runtime-only dependencies out of the glibc build graph" >&2
	exit 1
fi

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
