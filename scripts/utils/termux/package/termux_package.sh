# shellcheck shell=bash

# Title:          termux_package
# Description:    A library for Termux package utils.



##
# Check if package on device builds are supported by checking
# `$TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED` value in its `build.sh`
# file.
# .
# .
# **Parameters:**
# `package_dir` - The directory path for the package `build.sh` file.
# .
# **Returns:**
# Returns `0` if supported, otherwise `1`.
# .
# .
# termux_package__is_package_on_device_build_supported `<package_dir>`
##
termux_package__is_package_on_device_build_supported() {

    # shellcheck disable=SC1091
    [[ "$(. "$1/build.sh"; echo "$TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED")" != "true" ]]
    return $?

}



##
# Check if a specific version of a package has been built by checking
# the `$TERMUX_BUILT_PACKAGES_DIRECTORY/<package_name>` file.
# .
# .
# **Parameters:**
# `package_name` - The package name for the package.
# `package_version` - The package version for the package to check.
# .
# **Returns:**
# Returns `0` if built, otherwise `1`.
# .
# .
# termux_package__is_package_version_built `<package_name>` `<package_version>`
##
termux_package__is_package_version_built() {

    # bash builtins only, a bit faster than [ -e $file ] && [ "$(cat $file)" == "smth" ]
    [[ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY/$1" ]] && [[ "$(< "$TERMUX_BUILT_PACKAGES_DIRECTORY/$1")" == "$2" ]]
    return $?

}



##
# Check if the package name has a prefix called `glibc` or `glibc32`.
# .
# .
# **Parameters:**
# `package_name` - The package name for the package.
# .
# **Returns:**
# Returns `0` if have, otherwise `1`.
# .
# .
# termux_package__is_package_name_have_glibc_prefix `<package_name>`
##
termux_package__is_package_name_have_glibc_prefix() {

    for __pkgname_part in ${1//-/ }; do
        if [ "$__pkgname_part" = "glibc" ] || [ "$__pkgname_part" = "glibc32" ]; then
            return 0
        fi
    done

    return 1

}



##
# Adds the prefix `-glibc` to the package name
# .
# .
# **Parameters:**
# `package_name` - Package name.
# .
# **Returns:**
# Returns a modified package name.
# .
# .
# termux_package__add_prefix_glibc_to_package_name `<package_name>`
##
termux_package__add_prefix_glibc_to_package_name() {

    if [[ "${1}" = *"-static" ]]; then
        echo "${1/-static/-glibc-static}"
    else
        echo "${1}-glibc"
    fi

}

termux_package__is_glibc_classical_bridge_dependency() {

    case "${1}" in
        resolv-conf)
            return 0
            ;;
    esac

    return 1

}



##
# Adds the prefix `-glibc` to the list of package names if necessary.
# .
# .
# **Parameters:**
# `package_list` - List of package names (eg `TERMUX_PKG_DEPENDS`).
# .
# **Returns:**
# Returns a modified list of package names.
# .
# .
# termux_package__add_prefix_glibc_to_package_list `<package_list>`
##
termux_package__add_prefix_glibc_to_package_list() {

    local packages=""
    local package_separator=""
    local -a dependency_clauses

    IFS=',' read -r -a dependency_clauses <<< "$1"
    for __clause in "${dependency_clauses[@]}"; do
        local transformed_clause=""
        local alternative_separator=""
        local -a alternatives

        IFS='|' read -r -a alternatives <<< "$__clause"
        for __alternative in "${alternatives[@]}"; do
            local dependency="${__alternative#"${__alternative%%[![:space:]]*}"}"
            dependency="${dependency%"${dependency##*[![:space:]]}"}"

            local package_name="${dependency%%[[:space:](<>=]*}"
            local dependency_suffix="${dependency#"${package_name}"}"
            if [[ -n "${package_name}" ]] &&
                ! termux_package__is_glibc_classical_bridge_dependency "${package_name}" &&
                ! termux_package__is_package_name_have_glibc_prefix "${package_name}"; then
                dependency="$(termux_package__add_prefix_glibc_to_package_name "${package_name}")${dependency_suffix}"
            fi

            transformed_clause+="${alternative_separator}${dependency}"
            alternative_separator=" | "
        done

        packages+="${package_separator}${transformed_clause}"
        package_separator=", "
    done

    echo "${packages}"

}
