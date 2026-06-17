#!/usr/bin/env bash

if [[ -z "${TERMUXD_REPO_ROOT:-}" ]]; then
	TERMUXD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

: "${TERMUXD_ROOT_PATH:=/data/local/tmp/termuxd}"
: "${TERMUXD_RUNTIME_PATH:=${TERMUXD_ROOT_PATH}/runtime}"
: "${TERMUXD_PREFIX_PATH:=${TERMUXD_RUNTIME_PATH}/usr}"
: "${TERMUXD_GLIBC_PREFIX_PATH:=${TERMUXD_PREFIX_PATH}/glibc}"
: "${TERMUXD_CACHE_PATH:=${TERMUXD_ROOT_PATH}/cache}"
: "${TERMUXD_RUNTIME_ABI:=aarch64}"
: "${TERMUXD_ANDROID_API:=31}"
: "${TERMUXD_BIONIC_APT_REPO_URL:=https://ykmmj.github.io/termuxd-packages-repo/apt/bionic}"
: "${TERMUXD_BIONIC_APT_REPO_DISTRIBUTION:=stable}"
: "${TERMUXD_BIONIC_APT_REPO_COMPONENT:=main}"
: "${TERMUXD_GLIBC_APT_REPO_URL:=https://ykmmj.github.io/termuxd-packages-repo/apt/glibc}"
: "${TERMUXD_GLIBC_APT_REPO_DISTRIBUTION:=stable}"
: "${TERMUXD_GLIBC_APT_REPO_COMPONENT:=main}"
: "${TERMUXD_BIONIC_APT_SOURCE:=deb [trusted=yes] ${TERMUXD_BIONIC_APT_REPO_URL} ${TERMUXD_BIONIC_APT_REPO_DISTRIBUTION} ${TERMUXD_BIONIC_APT_REPO_COMPONENT}}"
: "${TERMUXD_GLIBC_APT_SOURCE:=deb [trusted=yes] ${TERMUXD_GLIBC_APT_REPO_URL} ${TERMUXD_GLIBC_APT_REPO_DISTRIBUTION} ${TERMUXD_GLIBC_APT_REPO_COMPONENT}}"
: "${TERMUXD_BIONIC_ROOT_PACKAGES:=apt bash}"
: "${TERMUXD_BIONIC_BUILD_PACKAGES:=${TERMUXD_BIONIC_ROOT_PACKAGES}}"
: "${TERMUXD_MINIMAL_BASH:=true}"
: "${TERMUXD_GLIBC_PACKAGES:=glibc-runner}"
: "${TERMUXD_GLIBC_SEED_PACKAGES:=linux-api-headers-glibc glibc}"
: "${TERMUXD_BUILD_PACKAGE_MODE:=auto}"
: "${TERMUXD_GLIBC_SEED_MODE:=auto}"
: "${TERMUXD_BUILD_JOBS:=4}"
: "${TERMUXD_USE_DOCKER:=true}"
: "${TERMUXD_REBUILD_ROOT_PACKAGES:=true}"
: "${TERMUXD_CONTAINER_NAME:=termuxd-package-builder}"
: "${TERMUXD_GLIBC_CONTAINER_NAME:=termuxd-glibc-package-builder}"
: "${TERMUXD_GLIBC_BUILDER_IMAGE_NAME:=ghcr.io/termux/package-builder-cgct}"
: "${TERMUXD_RESET_GLIBC_CONTAINER:=false}"
: "${TERMUXD_OUTPUT_DIR:=${TERMUXD_REPO_ROOT}/output}"
: "${TERMUXD_DIST_DIR:=${TERMUXD_REPO_ROOT}/out/termuxd-runtime-${TERMUXD_RUNTIME_ABI}}"
: "${TERMUXD_GLIBC_PACKAGES_SOURCE_DIR:=${TERMUXD_REPO_ROOT}/../glibc-packages}"
: "${TERMUXD_GLIBC_PACKAGES_WORK_DIR:=${TERMUXD_REPO_ROOT}/build/termuxd-glibc-packages}"

export TERMUXD_REPO_ROOT
export TERMUXD_ROOT_PATH
export TERMUXD_RUNTIME_PATH
export TERMUXD_PREFIX_PATH
export TERMUXD_GLIBC_PREFIX_PATH
export TERMUXD_CACHE_PATH
export TERMUXD_RUNTIME_ABI
export TERMUXD_ANDROID_API
export TERMUXD_BIONIC_APT_REPO_URL
export TERMUXD_BIONIC_APT_REPO_DISTRIBUTION
export TERMUXD_BIONIC_APT_REPO_COMPONENT
export TERMUXD_GLIBC_APT_REPO_URL
export TERMUXD_GLIBC_APT_REPO_DISTRIBUTION
export TERMUXD_GLIBC_APT_REPO_COMPONENT
export TERMUXD_BIONIC_APT_SOURCE
export TERMUXD_GLIBC_APT_SOURCE
export TERMUXD_BIONIC_ROOT_PACKAGES
export TERMUXD_BIONIC_BUILD_PACKAGES
export TERMUXD_MINIMAL_BASH
export TERMUXD_GLIBC_PACKAGES
export TERMUXD_GLIBC_SEED_PACKAGES
export TERMUXD_BUILD_PACKAGE_MODE
export TERMUXD_GLIBC_SEED_MODE
export TERMUXD_BUILD_JOBS
export TERMUXD_USE_DOCKER
export TERMUXD_REBUILD_ROOT_PACKAGES
export TERMUXD_CONTAINER_NAME
export TERMUXD_GLIBC_CONTAINER_NAME
export TERMUXD_GLIBC_BUILDER_IMAGE_NAME
export TERMUXD_RESET_GLIBC_CONTAINER
export TERMUXD_OUTPUT_DIR
export TERMUXD_DIST_DIR
export TERMUXD_GLIBC_PACKAGES_SOURCE_DIR
export TERMUXD_GLIBC_PACKAGES_WORK_DIR

termuxd_append_arg() {
	local var_name="$1"
	shift
	local addition="$*"
	local current="${!var_name:-}"

	if [[ -z "${addition}" ]]; then
		return
	fi

	if [[ -n "${current}" ]]; then
		printf -v "${var_name}" '%s %s' "${current}" "${addition}"
	else
		printf -v "${var_name}" '%s' "${addition}"
	fi
}

termuxd_prepare_docker_env_args() {
	TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS="${TERMUX_DOCKER_RUN_EXTRA_ARGS:-}"
	TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS="${TERMUX_DOCKER_EXEC_EXTRA_ARGS:-}"

	local proxy_name proxy_value
	for proxy_name in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
		proxy_value="${!proxy_name:-}"
		if [[ -n "${proxy_value}" ]]; then
			termuxd_append_arg TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS "--env ${proxy_name}=${proxy_value}"
			termuxd_append_arg TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS "--env ${proxy_name}=${proxy_value}"
		fi
	done
}

termuxd_clear_built_markers() {
	if [[ "${TERMUXD_REBUILD_ROOT_PACKAGES}" != "true" ]]; then
		return
	fi

	if [[ "$#" -eq 0 ]]; then
		return
	fi

	mkdir -p /data/data/.built-packages
	local package_name
	for package_name in "$@"; do
		rm -f "/data/data/.built-packages/${package_name}"
	done
}

termuxd_package_index_url() {
	local repo_url="$1"
	local distribution="$2"
	local component="${3:-${TERMUXD_BIONIC_APT_REPO_COMPONENT}}"
	local abi="${4:-${TERMUXD_RUNTIME_ABI}}"

	printf '%s/dists/%s/%s/binary-%s/Packages\n' \
		"${repo_url%/}" \
		"${distribution}" \
		"${component}" \
		"${abi}"
}

termuxd_read_url() {
	local url="$1"

	case "${url}" in
		file://*) cat -- "${url#file://}" ;;
		http://*|https://*) curl -fsSL --retry 1 --connect-timeout 10 --max-time 30 "${url}" ;;
		*) cat -- "${url}" ;;
	esac
}

termuxd_remote_package_index_has_records() {
	local repo_url="$1"
	local distribution="$2"
	local component="${3:-${TERMUXD_BIONIC_APT_REPO_COMPONENT}}"
	local abi="${4:-${TERMUXD_RUNTIME_ABI}}"
	local index_url

	index_url="$(termuxd_package_index_url "${repo_url}" "${distribution}" "${component}" "${abi}")"
	termuxd_read_url "${index_url}" 2>/dev/null | awk '/^Package: / { found = 1; exit } END { exit found ? 0 : 1 }'
}

termuxd_resolve_build_package_args() {
	local repo_url="$1"
	local distribution="$2"
	local output_var="$3"
	local mode="${TERMUXD_BUILD_PACKAGE_MODE}"
	local -a termuxd_resolved_args=()

	case "${mode}" in
		auto)
			if termuxd_remote_package_index_has_records "${repo_url}" "${distribution}"; then
				termuxd_resolved_args=(-I)
				echo "Remote APT package index has records; build-package will reuse packages with -I: ${repo_url}"
			else
				echo "Remote APT package index is empty or unavailable; build-package will reuse local built markers and build missing dependencies: ${repo_url}"
			fi
			;;
		none|false|off|local)
			;;
		*)
			read -r -a termuxd_resolved_args <<< "${mode}"
			;;
	esac

	local -n output_args="${output_var}"
	output_args=("${termuxd_resolved_args[@]}")
}

termuxd_should_seed_glibc_prefix() {
	local repo_url="$1"
	local distribution="$2"
	local component="$3"
	local abi="$4"

	case "${TERMUXD_GLIBC_SEED_MODE}" in
		auto)
			termuxd_remote_package_index_has_records "${repo_url}" "${distribution}" "${component}" "${abi}"
			;;
		always|true|force)
			return 0
			;;
		never|false|none|off|skip)
			return 1
			;;
		*)
			echo "Unknown TERMUXD_GLIBC_SEED_MODE: ${TERMUXD_GLIBC_SEED_MODE}" >&2
			return 1
			;;
	esac
}
