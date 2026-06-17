#!/usr/bin/env bash
set -euo pipefail

TERMUXD_INVOCATION_DIR="${PWD}"
TERMUXD_BUILD_LOG="${TERMUXD_BUILD_LOG:-${TERMUXD_INVOCATION_DIR}/termuxd-bionic-build-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "${TERMUXD_BUILD_LOG}")"
touch "${TERMUXD_BUILD_LOG}"
echo "Writing build log to ${TERMUXD_BUILD_LOG}"
exec > >(tee -a "${TERMUXD_BUILD_LOG}") 2>&1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/termuxd/config.sh
source "${script_dir}/config.sh"

read -r -a build_packages <<< "${TERMUXD_BIONIC_BUILD_PACKAGES}"
if [[ ${#build_packages[@]} -eq 0 ]]; then
	echo "TERMUXD_BIONIC_BUILD_PACKAGES is empty" >&2
	exit 1
fi

cd "${TERMUXD_REPO_ROOT}"
bash scripts/termuxd-check-config.sh

build_package_args=()
termuxd_resolve_build_package_args \
	"${TERMUXD_BIONIC_APT_REPO_URL}" \
	"${TERMUXD_BIONIC_APT_REPO_DISTRIBUTION}" \
	build_package_args
args=(-a "${TERMUXD_RUNTIME_ABI}")
if [[ -n "${TERMUXD_BUILD_JOBS}" ]]; then
	args+=(-j "${TERMUXD_BUILD_JOBS}")
fi
args+=("${build_package_args[@]}")

echo "Building termuxd bionic packages: ${build_packages[*]}"
echo "Requested build package mode: ${TERMUXD_BUILD_PACKAGE_MODE}"
echo "Build jobs: ${TERMUXD_BUILD_JOBS:-build-package default}"
echo "Minimal bash dependency mode: ${TERMUXD_MINIMAL_BASH}"
if [[ ${#build_package_args[@]} -gt 0 ]]; then
	echo "Resolved build package args: ${build_package_args[*]}"
else
	echo "Resolved build package args: <none>"
fi

if [[ "${TERMUXD_USE_DOCKER}" == "true" ]]; then
	termuxd_prepare_docker_env_args
	termuxd_append_arg TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS "--env TERMUXD_MINIMAL_BASH=${TERMUXD_MINIMAL_BASH}"
	termuxd_append_arg TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS "--env TERMUXD_MINIMAL_BASH=${TERMUXD_MINIMAL_BASH}"
	if [[ "${TERMUXD_REBUILD_ROOT_PACKAGES}" == "true" ]]; then
		env \
			CONTAINER_NAME="${TERMUXD_CONTAINER_NAME}" \
			TERMUX_DOCKER_RUN_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS}" \
			TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS}" \
			./scripts/run-docker.sh bash -lc '
				set -euo pipefail
				mkdir -p /data/data/.built-packages
				for package_name in "$@"; do
					rm -f "/data/data/.built-packages/${package_name}"
				done
			' bash "${build_packages[@]}"
	fi
	exec env \
		CONTAINER_NAME="${TERMUXD_CONTAINER_NAME}" \
		TERMUXD_MINIMAL_BASH="${TERMUXD_MINIMAL_BASH}" \
		TERMUX_DOCKER_RUN_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_RUN_ARGS}" \
		TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUXD_EFFECTIVE_DOCKER_EXEC_ARGS}" \
		./scripts/run-docker.sh ./build-package.sh "${args[@]}" "${build_packages[@]}"
fi

termuxd_clear_built_markers "${build_packages[@]}"
exec env TERMUXD_MINIMAL_BASH="${TERMUXD_MINIMAL_BASH}" \
	./build-package.sh "${args[@]}" -o "${TERMUXD_OUTPUT_DIR}" "${build_packages[@]}"
