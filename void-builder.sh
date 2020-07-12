#!/bin/bash

# Brings in optparse(), die(), and bud()
# shellcheck source=lib/functions.sh
source lib/functions.sh
optparse "$@"

# Import alpine base builder
alpine=$(bud from "${created_by}/alpine-voidbuilder:${ARCH}_latest") || die "$buildah_count"
trap 'buildah rm "$alpine"; [ -z "$voidbuild" ] || buildah rm "$voidbuild"' EXIT
alpine_mount=$(bud mount "$alpine") || die "$buildah_count" \
    "Could not mount alpine! Bailing (see error above, you probably need to run in a 'bud unshare' session)"

# Build a void-based builder
voidbuild=$(bud from scratch) || die "$buildah_count"
bud mount "$voidbuild" || die "$buildah_count"
bud copy "$voidbuild" "$alpine_mount"/target / || die "$buildah_count"
bud copy "$voidbuild" void-mklive/keys/* /target/var/db/xbps/keys/ || die "$buildah_count"
bud run "$voidbuild" -- sh -c "xbps-reconfigure -a && mkdir -p /target/var/cache && \
                                  ln -s /var/cache/xbps /target/var/cache/xbps && \
                                  mkdir -p /target/etc/xbps.d
                                  echo 'noextract=/usr/share/zoneinfo/right*' >> /target/etc/xbps.d/noextract.conf && \
                                  echo 'noextract=/usr/share/locale*' >> /target/etc/xbps.d/noextract.conf && \
                                  echo 'noextract=/usr/share/man*' >> /target/etc/xbps.d/noextract.conf && \
                                  echo 'noextract=/usr/share/info*' >> /target/etc/xbps.d/noextract.conf" || die "$buildah_count"
bud run "$voidbuild" -- sh -c "XBPS_ARCH=${ARCH} xbps-install -yMU \
                                  --repository=${REPOSITORY}/current \
                                  --repository=${REPOSITORY}/current/musl \
                                  -r /target \
                                  ca-certificates" || die "$buildah_count" "Error installing ca-certificates"

if [ -n "$BASEPKG" ]
then
    echo "Installing '$BASEPKG'" >&2
    bud run "$voidbuild" -- sh -c "XBPS_ARCH=${ARCH} xbps-install -yMU \
                                      --repository=${REPOSITORY}/current \
                                      --repository=${REPOSITORY}/current/musl \
                                      ${BASEPKG} -r /target" || die "$buildah_count" "Could not install $BASEPKG"
fi

# We don't care if the removes fail. Likely they were never insalled on this arch, or can't be
buildah run "$voidbuild" -- sh -c "XBPS_ARCH=${ARCH} xbps-remove -y base-minimal -r /target" &>/dev/null || true
for exclude in $(<excludes)
do
    buildah run "$voidbuild" -- sh -c "XBPS_ARCH=${ARCH} xbps-remove -y ${exclude} -r /target " &>/dev/null || true
done

bud run "$voidbuild" -- sh -c "rm -rvf /var/xbps/cache/*" || die "$buildah_count" "Error cleaning cache"

# Commit void-voidbuilder
bud config --created-by "$created_by" "$voidbuild" || die "$buildah_count"
bud config --author "$author" --label name=void-voidbuilder "$voidbuild" || die "$buildah_count"
bud unmount "$voidbuild" || die "$buildah_count" "Could not unmount '$voidbuild'"
bud unmount "$alpine" || die "$buildah_count" "Could not unmount '$alpine'"
bud commit --squash "$voidbuild" "${created_by}/void-voidbuilder:${tag}" || die "$buildah_count"

# vim: set foldmethod=marker et ts=4 sts=4 sw=4 :
