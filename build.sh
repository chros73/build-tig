#!/usr/bin/env bash
#
# Build optimized version of tig into custom location
#   project version: 1.0.0
#   project URL: https://github.com/chros73/build-tig


# Set repo owner and project
owner=jonas
project=tig

# Specify overridable defaults for project to compile from:
: ${version:=2.3.2}                   # release version
: ${git_project:=master}              # git branch/commit: [master|5af544e]



#
# HERE BE DRAGONS!
#

set -e
set +x

# Whether to check hash of packages
check_hash_packages=true

# Set source directory
src_dir=$(cd $(dirname "$0") && pwd)
tarballs_dir="$src_dir/tarballs"

# Define empty arrays for hashes and package dependecies
src_pkg_hashes=()
build_cmd_deps=()

# Extra options handling (set some overridable defaults)
: ${curl_opts:=-sLS}
: ${cfg_opts:=}
: ${patch_build:=yes}
: ${optimize_build:=yes}
[[ "$optimize_build" = yes ]] && : ${make_opts:=-j4}
export tarballs_dir curl_opts cfg_opts make_opts


esc=$(echo -en \\0033)
bold="$esc[1m"
off="$esc[0m"

bold() { # [message] : Display bold message
    echo "$bold$1$off"
}

fail() { # [message] : Display bold message and exit immediately
    bold "ERROR: $@"
    exit 1
}


get_latest_release_info() { # ["version_only"] : Get latest release info from GitHub
    # Latest GitHub release URL
    local latest_release_info_url="https://api.github.com/repos/$owner/$project/releases/latest"

    mkdir -p "$tarballs_dir"

    [[ -f "$tarballs_dir/latest_release_info" ]] || ( curl $curl_opts -o "$tarballs_dir/latest_release_info" "$latest_release_info_url" ) || true

    [[ -f "$tarballs_dir/latest_release_info" ]] && tag_name=$(egrep -o "$project-.*[^\",]" "$tarballs_dir/latest_release_info" | head -1)

    # Exit with error if couldn't get latest version information for building latest version
    if [ "$tag_name" == "" ]; then
        [[ "$1" == "version_only" ]] && return 0

        fail "Couldn't get latest version information!"
    fi

    version="${tag_name##*-}"

    if [ "$1" != "version_only" ]; then
        local md5_url=$(egrep -o "http.*/$owner/$project/releases/download/.*md5" "$tarballs_dir/latest_release_info" | head -1)

        if [ "$md5_url" != "" ]; then
            [[ -f "$tarballs_dir/$tag_name.tar.gz.md5" ]] || ( curl $curl_opts -o "$tarballs_dir/$tag_name.tar.gz.md5" "$md5_url")
            md5_hash=$(grep "$tag_name" "$tarballs_dir/$tag_name.tar.gz.md5" | cut -f 1 -d " " )

            [[ "$md5_hash" != "" ]] && src_pkg_hashes+=("$tag_name.tar.gz:$md5_hash")
        fi
    fi
}

# Dealing with optional 2nd "latest" argument: update necessary variables
[[ ! "$only_git_project" = true ]] && [[ "$2" = "latest" ]] && get_latest_release_info


# Support only git version of project (not major releases) ?
only_git_project=false

# Update necessary variables if git version is selected
[[ "$only_git_project" = true ]] || [[ "$2" = "git" ]] && get_latest_release_info version_only

# Set main project variables
rel_major="${version%.*}"
rel_minor="${version##*.}"
# Get rid of any possible letter in minor version number (e.g. 'b' , '-rc3')
patt='([[:digit:]]+)'
[[ "$rel_minor" =~ "$patt" ]] && rel_minor="${BASH_REMATCH[1]}"

# Let's fake the version number of the git version to be compatible with our patching system
git_minor=$[$rel_minor + 1]

set_git_env_vars() { # Reset project env var if git is used
    git_version="${rel_major}.${git_minor}-${git_project}"
    version="$git_version"

    build_cmd_deps+=('autoconf:autoconf')
    build_cmd_deps+=('automake:aclocal')
    build_cmd_deps+=('automake:automake')
    build_cmd_deps+=('pkg-config:pkg-config')
}

# Only support git version or dealing with optional 2nd "git" argument: update necessary variables
[[ "$only_git_project" = true ]] || [[ "$2" = "git" ]] && set_git_env_vars



# Define tag name if it doesn't exist already
tag_name="$project-$version"

# Extra options handling (set some overridable defaults)
: ${install_root:=$HOME}
inst_dir="$install_root/lib/$tag_name"
: ${root_sys_dir:=/usr/local}
: ${root_pkg_dir:=/opt}
root_symlink_dir="$root_pkg_dir/$project"
pkg_inst_dir="$root_symlink_dir-$version"
export inst_dir


# Fix people's broken systems
[[ "$(tr A-Z a-z <<<${LANG/*.})" = "utf-8" ]] || export LANG=en_US.UTF-8
unset LC_ALL
export LC_ALL

# Select build tools (prefer 'g' variants if available)
command which gmake &>/dev/null && export make_bin=gmake || export make_bin=make

# Set sed command
sed_i="sed -i -e"

# Platform magic
platform=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$platform" in
    freebsd)
        sed_i="sed -i '' -e"
        ;;
esac


# Debian-like package deps
build_pkg_deps=( libncursesw5-dev libreadline-dev libtinfo-dev git locales )


# gcc optimization
[[ "$optimize_build" = yes ]] && export CFLAGS="-march=native -pipe -O2 -fomit-frame-pointer${CFLAGS:+ }${CFLAGS}"
[[ -z "${CXXFLAGS+x}" ]] && [[ -z "${CFLAGS+x}" ]] || \
    export CXXFLAGS="${CFLAGS}${CXXFLAGS:+ }${CXXFLAGS}"


display_env_vars() { # Display env vars
    echo
    echo "${bold}Env for building ${project} into '${inst_dir}'${off}"
    echo
    printf 'optimize_build="%s"\n'            "${optimize_build}"
    [[ -z "${CFLAGS+x}" ]] || \
        printf 'export CFLAGS="%s"\n'         "${CFLAGS}"
    [[ -z "${CXXFLAGS+x}" ]] || \
        printf 'export CXXFLAGS="%s"\n'       "${CXXFLAGS}"
    echo
    printf 'export inst_dir="%s"\n'           "${inst_dir}"
    echo
    printf 'export curl_opts="%s"\n'          "${curl_opts}"
    printf 'export make_opts="%s"\n'          "${make_opts}"
    printf 'export cfg_opts="%s"\n'           "${cfg_opts}"
    echo
}


# Directory definition
sub_dirs="$project-*[0-9]*"

# Source
tarballs=( "https://github.com/$owner/$project/releases/download/$tag_name/$tag_name.tar.gz" )

# Source package md5 hashes
src_pkg_hashes+=('tig-2.2.2.tar.gz:3b4a9f0fd8d18c1039863e6c4ace6e46')
src_pkg_hashes+=('tig-2.3.0.tar.gz:4244423e7cbffce2d7ab44ef34086eee')
src_pkg_hashes+=('tig-2.3.2.tar.gz:9a9c335258d768ec10c7f1f2de4aca26')

# Command dependency
build_cmd_deps+=('coreutils:md5sum')
build_cmd_deps+=('curl:curl')
build_cmd_deps+=('grep:egrep')
build_cmd_deps+=("build-essential:$make_bin")
build_cmd_deps+=('build-essential:gcc')



#
# HELPERS
#

clean() { # [package-version] : Clean up generated files in directory of packages
    local i sdir

    for i in $sub_dirs; do
        [[ -n "$1" && ! "$i" = "$1" ]] && continue
        sdir="${i%%-*}"
        ( cd "$i" && "$make_bin" clean && rm -rf "$tarballs_dir/DONE-$sdir" >/dev/null )
    done
}

clean_all() { # [package-version] : Remove all created directories in the working directory
    [[ -d "$tarballs_dir" ]] && [[ -f "$tarballs_dir/DONE-PKG" ]] && rm -f "$tarballs_dir/DONE-PKG" >/dev/null
    [[ -n "$1" ]] || [[ -f "$tarballs_dir/latest_release_info" ]] && rm -f "$tarballs_dir/latest_release_info" >/dev/null
    [[ -n "$1" ]] || [[ -f "$tarballs_dir/$tag_name.tar.gz.md5" ]] && rm -f "$tarballs_dir/$tag_name.tar.gz.md5" >/dev/null

    local i sdir

    for i in $sub_dirs; do
        [[ -n "$1" && ! "$i" = "$1" ]] && continue
        sdir="${i%%-*}"
        [[ ! -d "$i" ]] || rm -rf "$i" >/dev/null && rm -rf "$tarballs_dir/DONE-$sdir" >/dev/null
    done
}

check_deps() { # Check command and package dependency
    [[ -d "$install_root" ]] || fail "$install_root doesn't exist, it needs to be created first!"

    local dep pkg cmd have_dep='' installer=''

    for dep in "${build_cmd_deps[@]}"; do
        pkg="${dep%%:*}"
        cmd="${dep##*:}"

        if which "$cmd" &>/dev/null; then :; else
            echo "You don't have the '$cmd' command available, you likely need to:"
            bold "    sudo apt-get install $pkg"
            exit 1
        fi
    done

    if which dpkg &>/dev/null; then
        have_dep='dpkg -l'
        installer='apt-get install'
    elif which pacman &>/dev/null; then
        have_dep='pacman -Q'
        installer='pacman -S'
    fi

    if [[ -n "$installer" ]]; then
        for dep in "${build_pkg_deps[@]}"; do
            if ! $have_dep "$dep" &>/dev/null; then
                echo "You don't have the '$dep' package installed, you likely need to:"
                bold "    sudo $installer $dep"
                exit 1
            fi
        done
    fi
}

prep() { # Check dependency and create basic directories
    [[ -f "$inst_dir/bin/$project" ]] && fail "Current '$version' version is already built in '$inst_dir', it has to be removed manually before a new compilation."

    check_deps
    mkdir -p "$install_root"/{bin,lib}
    mkdir -p "$tarballs_dir"
}

check_hash() { # [package-version.tar.gz] : md5 hashcheck downloaded packages
    [[ "$check_hash_packages" = true ]] || return 0

    local srchash pkg hash

    for srchash in "${src_pkg_hashes[@]}"; do
        pkg="${srchash%%:*}"
        hash="${srchash##*:}"

        if [ "$1" == "$pkg" ]; then
            echo "$hash  $tarballs_dir/$pkg" | md5sum -c --status &>/dev/null && break
            rm -f "$tarballs_dir/$pkg" && fail "Checksum failed for $pkg"
        fi
    done
}

download() { # [package-version] : Download and unpack sources
    [[ -d "$tarballs_dir" ]] && [[ -f "$tarballs_dir/DONE-PKG" ]] && rm -f "$tarballs_dir/DONE-PKG" >/dev/null

    local url url_base tarball_dir

    for url in "${tarballs[@]}"; do
        # skip downloading project here if git version should be used
        [[ "$version" = "$git_version" ]] && continue

        url_base="${url##*/}"
        tarball_dir="${url_base%.tar.gz}"
        [[ -n "$1" && ! "$tarball_dir" = "$1" ]] && continue
        [[ -f "$tarballs_dir/${url_base}" ]] || ( echo "Getting $url_base" && command cd "$tarballs_dir" && curl -O $curl_opts "$url" )
        [[ -d "$tarball_dir" ]] || ( check_hash "$url_base" && echo "Unpacking $url_base" && tar xfz "$tarballs_dir/$url_base" || fail "Tarball $url_base could not be unpacked." )
    done

    if [ "$version" = "$git_version" ]; then
        download_git "$owner" "$project" "$git_project"
    fi

    touch "$tarballs_dir/DONE-PKG"
}

download_git() { # owner project commit|branch : Download from GitHub
    local owner="$1" repo="$2" repo_ver="$3" url

    url="https://github.com/$owner/$repo/archive/$repo_ver.tar.gz"
    [[ -f "$tarballs_dir/$repo-$repo_ver.tar.gz" ]] || ( echo "Getting $repo-$repo_ver.tar.gz" && command cd "$tarballs_dir" && curl $curl_opts -o "$repo-$repo_ver.tar.gz" "$url" )
    rm -rf "$repo-$repo_ver"* >/dev/null && ( check_hash "$repo-$repo_ver.tar.gz" && echo "Unpacking $repo-$repo_ver.tar.gz" && tar xfz "$tarballs_dir/$repo-$repo_ver.tar.gz" || fail "Tarball $repo-$repo_ver.tar.gz could not be unpacked.")
    [[ ! -d "$repo-$version" ]] && mv "$repo-$repo_ver"* "$repo-$version" || fail "'$repo-$version' dir is already exist so temp dir '$repo-$repo_ver'* can't be renamed."
}

patch_project() { # Patch project
    # Bump version number for git version only
    [[ "$version" = "$git_version" ]] && $sed_i s%^VERSION.*=.*[0-9].*%VERSION\ =\ "$version"% "$tag_name/Makefile"

    [[ -d "$src_dir/patches" && "$patch_build" = yes ]] || return 0
    [[ -e "$tarballs_dir/DONE-PKG" ]] && [[ -d "$tag_name" ]] || fail "You need to '$0 download' first!"

    local version_number version_parts corepatch

    bold "~~~~~~~~~~~~~~~~~~~~~~~~   Patching $project   ~~~~~~~~~~~~~~~~~~~~~~~~~~"

    pushd "$tag_name"

    # Get rid of any possible letter in version number, e.g. '-master' (can be caused by git version)
    version_number="${version%-*}"
    version_parts=(${version_number//./ })
    [[ "${version_parts[0]}.${version_parts[1]}" == "$version_number" ]] && version_number=""

    for corepatch in "$src_dir/patches"/{"${version_parts[0]}","${version_parts[0]}.${version_parts[1]}","${version_number}",all}_{backport,debian,"${platform}",misc,override}_*.patch; do
        [[ ! -e "$corepatch" ]] || { bold "$(basename $corepatch)"; patch -uNp1 -i "$corepatch"; }
    done

    popd
}

build_project() { # Build project
    [[ -e "$tarballs_dir/DONE-PKG" ]] || fail "You need to '$0 download' first!"
    [[ -d "$tarballs_dir" ]] && [[ -f "$tarballs_dir/DONE-$project" ]] && rm -f "$tarballs_dir/DONE-$project" >/dev/null

    bold "~~~~~~~~~~~~~~~~~~~~~~~~   Building $project   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    ( set +x ; cd "$tag_name" \
        && [[ -f ./configure ]] || $make_bin $make_opts configure \
        && ./configure --prefix="$inst_dir" --with-ncursesw $cfg_opts \
        && $make_bin $make_opts \
        && $make_bin install \
        || fail "during building '$project'!" )

    touch "$tarballs_dir/DONE-$project"
}

install() { # Install project
    [[ -e "$tarballs_dir/DONE-PKG" ]] || fail "You need to '$0 download' first!"
    [[ -d "$tarballs_dir" ]] && [[ -f "$tarballs_dir/DONE-$project" ]] && [[ -f "$inst_dir/bin/$project" ]] || fail "Compilation of $tag_name hasn't been finished, try it again."
    [[ -d "$pkg_inst_dir" ]] && [[ -f "$pkg_inst_dir/bin/$project" ]] && fail "Could not clean install into dir '$pkg_inst_dir', dir already exists."

    bold "~~~~~~~~~~~~~~~~~~~~~~~~   Installing $project   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    cp -r "$inst_dir" "$root_pkg_dir/" || fail "Could not copy into dir '$pkg_inst_dir', have you tried with 'sudo'?"
    chmod -R a+rX "$pkg_inst_dir/"
}

symlink_binary_home() { # Symlink binary in "$install_root"
    [[ ! -f "$inst_dir/bin/$project" ]] && fail "Compilation of $tag_name hasn't been finished, try it again."

    cd "$install_root/lib"
    ln -nfs "$tag_name" "$project"
    cd "$install_root/bin"
    ln -nfs "../lib/$project/bin/$project" "$project"
    cd "$src_dir"
}

symlink_binary_inst() { # Symlink binary after it's installed into "$root_pkg_dir" dir
    [[ ! -f "$pkg_inst_dir/bin/$project" ]] && fail "Installation of $tag_name hasn't been finished, try it again."
    [[ -f "$root_sys_dir/bin/$project" ]] && [[ ! -L "$root_sys_dir/bin/$project" ]] && fail "Could not create symlink '$project' in '$root_sys_dir/bin/'"
    [[ -d "$root_sys_dir/lib/$project" || -f "$root_sys_dir/lib/$project" ]] && [[ ! -L "$root_sys_dir/lib/$project" ]] && fail "Could not create symlink '$project' in '$root_sys_dir/lib/'"
    [[ -d "$root_symlink_dir" || -f "$root_symlink_dir" ]] && [[ ! -L "$root_symlink_dir" ]] && fail "Could not create symlink '$project' in '$root_pkg_dir/'"

    cd "$root_pkg_dir"
    ln -nfs "$tag_name" "$project"
    ln -nfs "$root_symlink_dir" "$root_sys_dir/lib/$project"
    cd "$root_sys_dir/bin"
    ln -nfs "../lib/$project/bin/$project" "$project"
    cd "$src_dir"
}

check() { # root_dir : Print some diagnostic success indicators
    bold "Checking links:"
    echo

    if [ "$1" == "$install_root" ]; then
        echo "$1/bin/$project ->" $(readlink "$1/bin/$project") | sed -e "s:$HOME/:~/:g"
        echo "$1/lib/$project ->" $(readlink "$1/lib/$project") | sed -e "s:$HOME/:~/:g"
    else
        echo "$1/bin/$project ->" $(readlink "$1/bin/$project")
        echo "$1/lib/$project ->" $(readlink "$1/lib/$project")
        echo "$root_symlink_dir ->" $(readlink "$root_symlink_dir")
    fi

    # This first selects the rpath dependencies, and then filters out libs not found in the install dirs.
    # If anything is left, we have an external dependency that sneaked in.
    echo
    echo -n "Check that static linking worked: "
    local libs=$(ldd "$1/bin/$project")         #"
    if [[ "$(echo "$libs" | egrep "$1/bin" | wc -l)" -eq 0 ]]; then
        echo OK; echo
    else
        echo FAIL; echo; echo "Suspicious library paths are:"
        echo "$libs" | egrep "$1/bin" || :
        echo
    fi

    echo "Dependency library paths:"
    echo "$libs" | sed -e "s:$1/bin/::g"
}

info() { # Display info
    local i

    echo >&2 "${bold}Usage: $0 ($project [latest | git] | install [latest | git] | info [latest | git])$off"
    echo >&2 "Build $project into $(sed -e s:$HOME/:~/: <<<$inst_dir)"
    echo >&2
    echo >&2 "Custom environment variables:"
    echo >&2 "    curl_opts=\"${curl_opts}\" (e.g. --insecure)"
    echo >&2 "    make_opts=\"${make_opts}\""
    echo >&2 "    cfg_opts=\"${cfg_opts}\" (e.g. --enable-debug --enable-extra-debug)"
    echo >&2
    echo >&2 "Build actions:"
    grep ").\+##" "$0" | grep -v grep | sed -e "s:^:  :" -e "s:): :" -e "s:## ::" | while read i; do
        eval "echo \"   $i\""
    done
    exit 1
}



#
# MAIN
#
cd "$src_dir"
case "$1" in
    info)       ## Display info (taking into account the optional 2nd 'latest' or 'git' argument)
                info
                ;;
    tig)        ## Build all components into $(sed -e s:"$HOME"/:~/: <<<"$inst_dir")
                display_env_vars
                prep
                clean_all
                download
                patch_project
                build_project
                display_env_vars
                symlink_binary_home
                check "$install_root"
                ;;
    install)    ## Install $(sed -e s:"$HOME"/:~/: <<<"$inst_dir") compilation into "$pkg_inst_dir"
                install
                symlink_binary_inst
                check "$root_sys_dir"
                ;;

    # Dev related actions
    env-vars)   display_env_vars ;;
    clean)      clean ;;
    clean_all)  clean_all ;;
    deps)       check_deps ;;
    download)   prep; download ;;
    patch-tig)  display_env_vars; prep; clean_all; download; patch_project ;;
    build-tig)  display_env_vars; prep; clean_all; download; build_project ;;
    patchbuild) display_env_vars; prep; clean_all; download; patch_project; build_project ;;
    sm-home)    symlink_binary_home ;;
    sm-inst)    symlink_binary_inst ;;
    check-home) check "$install_root" ;;
    check-inst) check "$root_sys_dir" ;;
    *)          info ;;
esac
