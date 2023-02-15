#!/bin/bash
# CI build for github. Builds various Void Linux based images. See Readme.md

# shellcheck source=lib/functions.sh
source lib/functions.sh # Brings in optparse(), usage(), die(), and bud() functions, and sets default env vars

# Parse command line options
optparse "$@"

export BASEPKG ARCH REPOSITORY REPO_GLIBC REPO_GLIBC_BOOTSTRAP REPO_MUSL REPO_MUSL_BOOTSTRAP author created_by tag
export BUILDAH_FORMAT=oci
# export STORAGE_DRIVER=overlay2
export STORAGE_DRIVER=vfs

declare -a published_tags
# Normally would not set this, but we definitely want any error to be fatal in CI
set -e

scan_image() { # {{{
    tag=$1
    [ -d /oci ] || mkdir -p /oci
    shortname=$(basename "$IMAGE_NAME")
    oci_path=/oci/${shortname}_${tag}
    buildah push "$IMAGE_NAME:$tag" "oci:/$oci_path"
    ./trivy --exit-code 0 --severity HIGH --no-progress image --input "$oci_path"
    ./trivy --exit-code 1 --severity CRITICAL --no-progress image --input "$oci_path"
} # }}}

build_image() { # {{{
    tag=$1
    shift
    ./buildah.sh -t "$tag" "$@"
    # scan_image "$tag" || die 99 "Trivy scan failed!"
    published_tags+=( "$tag" )
} # }}}

build_image_from_builder() { # {{{
    tag=$1
    shift
    ./void-builder.sh -t "$tag" "$@"
    echo "Building final image for $tag" >&2
    ./voidlinux-final.sh -t "$tag" "$@"
    # scan_image "$tag" || die 99 "Trivy scan failed!"
    published_tags+=( "$tag" )
} # }}}

# Build standard minimal voidlinux with glibc (no glibc-locales)
build_image "${ARCH}"

# Various other glibc variants
# for tag in ${ARCH}-glibc-locales_latest glibc-locales-tiny glibc-tiny
build_image_from_builder "${ARCH}-glibc-tiny"
build_image_from_builder "${ARCH}-glibc-locales-tiny"

# Build tiny voidlinux with tmux, using glibc and busybox, no coreutils. Strip all libs
# tag=tmux-tiny
# build_image_from_builder "$tag" -b "tmux ncurses-base"

build_image_from_builder "masterdir-${ARCH}" -b "base-chroot"

# Build minimal voidlinux with musl (no glibc)
export ARCH="${ARCH}-musl"
build_image "${ARCH}"

# Build tiny voidlinux with musl (no glibc) and busybox instead of coreutils
build_image_from_builder "${ARCH}-tiny"

# Build voidlinux with tmux, using musl and coreutils. Unstripped
# tag=musl-tmux
# build_image_from_builder "$tag" -b "base-minimal tmux ncurses-base" -c "/usr/bin/tmux"

# Build tiny voidlinux with tmux, using musl and busybox, no coreutils. Strip all libs
# tag=musl-tmux-tiny
# build_image_from_builder "$tag" -b "tmux ncurses-base" -c "/usr/bin/tmux"

# Build tiny voidlinux with ruby, using musl and busybox, no coreutils. Strip all libs
# tag=musl-ruby-tiny
# build_image_from_builder "$tag" -b "ruby"

# publish images _only_ if we're run in CI. This allows us to mimic the whole
# build locally in the exact manner the CI builder does, without any publishing to registries
if [ -n "$GHCR_TOKEN" ] # {{{
then
    export REGISTRY_AUTH_FILE=${HOME}/auth.json # Set registry file location
    export CI_REGISTRY=ghcr.io
    export CI_REGISTRY_USER=natrys

    echo "$GHCR_TOKEN" | buildah login --authfile=${HOME}/auth.json -u "$CI_REGISTRY_USER" --password-stdin "$CI_REGISTRY" # Login to registry
    
    : "${FQ_IMAGE_NAME:=${CI_REGISTRY}/${CI_REGISTRY_USER}/voidlinux}"
 
    # Show us all the images built
    buildah images

    set +x
    # Push everything to the registry
    for tag in "${published_tags[@]}"
    do
        echo "Publishing $tag"
        buildah push --authfile=${HOME}/auth.json "${created_by}/voidlinux:${tag}" "$FQ_IMAGE_NAME:${tag}"
    done

    # Push the glibc-tiny image as the :latest tag TODO: find a way to tag this instead of committing a new image signature for it
    if [[ "$ARCH" =~ "x86_64" ]]; then
        echo "Publishing :latest tag for glibc-tiny"
        buildah push --authfile=${HOME}/auth.json "${created_by}/voidlinux:${ARCH/musl/glibc}-tiny" "$FQ_IMAGE_NAME:latest"
    fi
fi # }}}

# vim: set foldmethod=marker et ts=4 sts=4 sw=4 :
