#!/bin/bash

VERSION="2.2.0p36"

if [ $# -gt 0 ]; then
  VERSION="$1"
fi

start_time=$(date +%s)

echo "`date +%Y-%m-%d_%H-%M-%S` building Check_MK ${VERSION}..."

echo "updating the build system ..."
apt-get -y update && apt-get -y upgrade

cd /opt/build-mk

if [ ! -d check-mk-raw-${VERSION}.cre ]; then
   echo "checking if check-mk source exists ..."
   if [ ! -f check-mk-raw-${VERSION}.cre.tar.gz ]; then
      echo "getting check-mk source ..."
      wget -q https://download.checkmk.com/checkmk/${VERSION}/check-mk-raw-${VERSION}.cre.tar.gz
   fi
   echo "untar check-mk source ..."
   tar xfz check-mk-raw-${VERSION}.cre.tar.gz
fi

# get check_mk for windows artifact extraction
#
# The Windows agent binaries are not built here, they are lifted out of an
# official amd64 package. Upstream took them from the `mantic` build, which
# Checkmk has since withdrawn along with Ubuntu 23.10 — it 404s for 2.2.0p47.
# `bookworm` is still published and matches this image's base. The guard also
# used to name a third distro (`kinetic`), so it never matched the file the
# wget below wrote and the download repeated on every run.
DONOR_DEB="check-mk-cloud-${VERSION}_0.bookworm_amd64.deb"
if [ ! -f "${DONOR_DEB}" ]; then
    wget https://download.checkmk.com/checkmk/${VERSION}/${DONOR_DEB}
fi

# create symlink to c++-12 compiler if not exists
if [ ! -f /usr/bin/g++-12 ]; then
   echo "create symlink to c++-12 ..."
   ln -sf /usr/bin/g++ /usr/bin/g++-12
fi

# create symlink to c++-13 compiler if not exists
if [ ! -f /usr/bin/g++-13 ]; then
   echo "create symlink to c++-13 ..."
   ln -sf /usr/bin/g++ /usr/bin/g++-13
fi

python3.11 -m pip install --upgrade pip

export USE_EXTERNAL_PIPENV_MIRROR=true

echo "going to check-mk source path ...."
cd check-mk-raw-${VERSION}.cre

# Install all .patch files that dont start with 'ZZZ__'
echo "installing patches ...."
for FILE in "../patches/"*.patch; do
   if [ -f "$FILE" ]; then
      BASENAME=$(basename "$FILE")
      if [[ "$BASENAME" != ZZZ___* ]]; then
         patch -l -f -p0 < $FILE > /dev/null
         if [ $? != 0 ]; then
            echo "failure with Patch: $BASENAME"
         else 
            echo "success with Patch: $BASENAME"
         fi 
      fi
   fi
done

### Copy Pipfile.lock

cp ../patches/Pipfile.lock .

./configure

echo "prepare windows artifacts ..."
ar x ../${DONOR_DEB}
# 2.2 donor debs ship data.tar.xz; 2.3+ switched to zstd. Take whichever the
# ar archive actually contains instead of hardcoding one.
DONOR_DATA=$(ls data.tar.* 2>/dev/null | head -n1)
case "${DONOR_DATA}" in
   "")    echo "no data.tar.* member in ${DONOR_DEB}" ;;
   *.zst) tar -I zstd -xf "${DONOR_DATA}" ;;
   *)     tar -xf "${DONOR_DATA}" ;;
esac
# Nothing above this line uses `set -e`, so guard the swap: if the donor
# extraction failed, the rm would still fire and the build would go on to
# produce a package with no Windows agents at all.
[ -d opt/omd/versions/${VERSION}.cce/share/check_mk/agents/windows ] ||
   { echo "no Windows agents in ${DONOR_DEB} — refusing to gut agents/windows"; exit 1; }
rm -rf agents/windows
mv opt/omd/versions/${VERSION}.cce/share/check_mk/agents/windows agents/

echo "updating nagios archive for supporting aarch64 ..."
tar xzf omd/packages/nagios/nagios-3.5.1.tar.gz -C /tmp
cp /usr/share/misc/config.guess /tmp/nagios-3.5.1/
tar czf omd/packages/nagios/nagios-3.5.1.tar.gz -C /tmp nagios-3.5.1
rm -rf /tmp/nagios-3.5.1

echo "updating pnp4nagios archive for supporting aarch64 ..."
tar xzf omd/packages/pnp4nagios/pnp4nagios-0.6.26.tar.gz -C /tmp
cp /usr/share/misc/config.guess /tmp/pnp4nagios-0.6.26/
tar czf omd/packages/pnp4nagios/pnp4nagios-0.6.26.tar.gz -C /tmp pnp4nagios-0.6.26
rm -rf /tmp/pnp4nagios-0.6.26

echo "updating stunnel archive for supporting aarch64 ..."
tar xzf omd/packages/stunnel/stunnel-5.63.tar.gz -C /tmp
cp /usr/share/misc/config.guess /tmp/stunnel-5.63/
tar czf omd/packages/stunnel/stunnel-5.63.tar.gz -C /tmp stunnel-5.63
rm -rf /tmp/stunnel-5.63

echo "updating snap7 archive for supporting aarch64 ..."
tar xzf omd/packages/snap7/snap7-1.4.2.tar.gz -C /tmp
cp /tmp/snap7-1.4.2/build/unix/arm_v6_linux.mk /tmp/snap7-1.4.2/build/unix/aarch64_linux.mk
sed -i  's/arm_v6/aarch64/' /tmp/snap7-1.4.2/build/unix/aarch64_linux.mk
tar czf omd/packages/snap7/snap7-1.4.2.tar.gz -C /tmp snap7-1.4.2
rm -rf /tmp/snap7-1.4.2

# setup pipenv
bash buildscripts/infrastructure/build-nodes/scripts/install-pipenv.sh

echo "starting make deb ..."
# compile and package
make deb DEBFULLNAME="Martin Petersen" DEBEMAIL=martin@petersen20.de

if [ $? -eq 0 ]; then
    cp check-mk-raw-${VERSION}*.deb /opt/build-mk/debs/
    cd ..
    echo "`date +%Y-%m-%d_%H-%M-%S` SUCCESS :-)"
    end_time=$(date +%s)
    elapsed=$(( end_time - start_time ))
    eval "echo Elapsed time: $(date -ud "@$elapsed" +'$((%s/3600/24)) days %H hr %M min %S sec')"
fi
