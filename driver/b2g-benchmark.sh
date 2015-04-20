#!/bin/sh


B2G_DIR=${B2G_DIR:-/home/awsa/unagi/B2G}
if test -d "$1"; then
    B2G_DIR=$1
    shift;
fi

SHARED_SETUP_DIR=${SHARED_SETUP_DIR-/home/awsa}
PERSO_SETUP_DIR=${PERSO_SETUP_DIR:-$B2G_DIR/perso}

# Needed by gaia-ui-tests
GAIA_UI_TESTS=$PERSO_SETUP_DIR/gaia-ui-tests
INSTALL_DIR=$PERSO_SETUP_DIR/.usr
export PYTHONPATH=$INSTALL_DIR/lib/python2.7/site-packages:
export PATH=$INSTALL_DIR/bin:$PATH


debug() {
  set -xe
}

help() {
  echo "
./run-benchmark.sh [checkout] [build] [flash] [benchmark] [upload]

Execute series of command in the same order as they appear on the
command line.
"
}

reportStage() {
  echo "##
##
## $@
##
##
"
}

# Utilities to help finding the corresponding changesets between mercurial and gecko.
changesetToCommit() {
#    ssh git@hydra changeset-to-commit "$1"
    local commit=$(ssh npierron@people.mozilla.org '~/changeset-to-commit.sh' "$1")
    if test -z "$commit" ; then
	commit="hg-$1"
    fi
    echo "$commit"
}

commitToChangeset() {
#    ssh git@hydra commit-to-changeset "$1"
    local chgset=$(ssh npierron@people.mozilla.org '~/commit-to-changeset.sh' "$1")
    if test -z "$chgset" ; then
	chgset="git-$1"
    fi
    echo "$chgset"
}

# Contains the identifer of the phone which is used by adb and
# fastboot to identify the right device when flashing it and running
# benchmarks on it.
FASTBOOT_SERIAL_FILE=$PERSO_SETUP_DIR/fastboot.serial
FASTBOOT_SERIAL_NO=$(cat $FASTBOOT_SERIAL_FILE)

ADB=adb
run_adb() {
    test -n "$ADB_FLAGS" || find_device_name
    $ADB $ADB_FLAGS $@ | tr -d '\r'
}

ADB_FLAGS=
FASTBOOT_FLAGS=
find_device_name() {
  if test -e $FASTBOOT_SERIAL_FILE; then
    if $ADB -s $FASTBOOT_SERIAL_NO shell "echo Device $FASTBOOT_SERIAL_NO found."; then
      ADB_FLAGS="-s $FASTBOOT_SERIAL_NO"
      FASTBOOT_FLAGS="-s $FASTBOOT_SERIAL_NO"
    else
      echo "Error: Device $FASTBOOT_SERIAL_NO not found!"
      exit 1
    fi
  else
    echo "Error: Device identifier file $FASTBOOT_SERIAL_FILE does not exists!"
    exit 1
  fi
}

find_device_name

# Local port on which the remote debugger protocol of the phone is
# forwarded.  This is used by marionette tests to command and inspect
# the phone during benchmarks.
LOCAL_PORT_FILE=$PERSO_SETUP_DIR/marionette.port

# Location of the settings with which the phone are used to run the
# benchmarks. This is shared because it is useful to be able to switch
# quickly from one wifi to another.
TESTVARS=$SHARED_SETUP_DIR/bench-testvars.json
WIFINET=$SHARED_SETUP_DIR/wifi.server.network

# This configuration file inform the standalone driver of AWFY how to
# upload results.
AWFY_CONFIG=$SHARED_SETUP_DIR/awfy.config
LOCAL_AWFY_CONFIG=$SHARED_SETUP_DIR/awfy-local.config

# Contains the identifer which is used to identify this build/engine
# on the remote server.
AWFY_ENGINE_FILE=$PERSO_SETUP_DIR/awfy.engine

# List of configure option to be given to gecko.
EXTRA_MOZCONFIG_FILE=$PERSO_SETUP_DIR/mozconfig.extra

##
## Functions used to setup the environment
##
installGaiaTestDeps() {
    apt-get install python-setuptools
}

installGaiaTest() {
    cd $(dirname $GAIA_UI_TESTS)
    git clone -b bench https://github.com/nbp/gaia-ui-tests.git
}

# sepacial the build directory for only one device.
installSerialBuild() {
    mkdir -p $PERSO_SETUP_DIR
    echo '2828' > $LOCAL_PORT_FILE
    run_adb shell 'getprop ro.serialno' > $FASTBOOT_SERIAL_FILE
    run_adb shell 'setprop persist.usb.serialno' $(cat $FASTBOOT_SERIAL_FILE)
    run_adb reboot
    cat - > $PERSO_SETUP_DIR/Android.mk <<EOF
LOCAL_PATH:= \$(call my-dir)

include \$(CLEAR_VARS)

LOCAL_MODULE := local.prop
LOCAL_MODULE_CLASS := DATA
LOCAL_MODULE_TAGS := optional eng user
LOCAL_MODULE_PATH := \$(TARGET_OUT_DATA)
include \$(BUILD_SYSTEM)/base_rules.mk

FASTBOOT_SERIAL_FILE := \$(LOCAL_PATH)/fastboot.serial
FASTBOOT_SERIAL_NO := \$(shell cat \$(FASTBOOT_SERIAL_FILE))

\$(LOCAL_BUILT_MODULE): PRIVATE_FASTBOOT_SERIAL_NO := \$(FASTBOOT_SERIAL_NO)
\$(LOCAL_BUILT_MODULE) : \$(FASTBOOT_SERIAL_FILE)
	@echo "Set iSerial to : \$(PRIVATE_FASTBOOT_SERIAL_NO)"
	@mkdir -p \$(dir \$@)
	echo "persist.usb.serialno=\$(PRIVATE_FASTBOOT_SERIAL_NO)" >  \$@
EOF
    touch $EXTRA_MOZCONFIG_FILE
}

updateManifest() {
  if test -e $PERSO_SETUP_DIR/update-manifest.sed; then
    cd $B2G_DIR/.repo/manifests
    sed -f $PERSO_SETUP_DIR/update-manifest.sed unagi.xml > awsa-unagi.xml
    ln -sf $B2G_DIR/.repo/manifests/awsa-unagi.xml $B2G_DIR/.repo/manifest.xml
  fi
}

##
## Functions used to wrap around the building process of B2G.
##

# Apply all patches which are in the given directory.  The directory
# into which patches are located is used to decide which repository
# has to be patched.
applyPatches() {
  local patchDir="$1"
  if test -d $patchDir; then
    for file in : $(cd $patchDir; find . -type f -name '*.patch' | sort); do
      test "$file" = : && continue;
      reportStage "Apply patch $file."
      patch -p1 -d $B2G_DIR/$(dirname $file) < $patchDir/$file
    done
  fi
}

undoPatches() {
  local patchDir="$1"
  if test -d $patchDir; then
    for file in : $(cd $patchDir; find . -type f -name '*.patch' | sort -r); do
      test "$file" = : && continue;
      cd $B2G_DIR/$(dirname $file)
      # git clean -xqfd
      git reset --hard
    done
  fi
}

cleanBeforeCheckout() {
  # Pull repository changes.
  cd $B2G_DIR/.repo/manifests
  git pull
  updateManifest

  # Reset all repositories which have been patched.
  undoPatches $PERSO_SETUP_DIR/patches

  # Clean-up any mess which might have been added by any commit modifying the sources.
  cd $B2G_DIR/gecko
  git reset --hard

  # Undo changes.
  cd $B2G_DIR/gaia
  git reset --hard

  # Undo configure file changes
  cd $B2G_DIR/gonk-misc
  git reset --hard
}

cleanAfterCheckout() {
  # Apply patches which are not yet accepted in the tree.
  applyPatches $PERSO_SETUP_DIR/patches

  # The silence fall.
  # http://blog.ginzburgconsulting.com/wp-content/uploads/2013/02/silent.ogg
  # https://github.com/mozilla-b2g/gaia/commit/0ec2a2558cf41da4a2bf52bf6a550e5e2293602c
  find $B2G_DIR/gaia -name \*.ogg | xargs -n 1 cp ~/silent.ogg

  # Erase the previous default config file with the patched version
  # which contains the configuration options dedicated to this device.
  cat $B2G_DIR/gonk-misc/default-gecko-config $EXTRA_MOZCONFIG_FILE > $EXTRA_MOZCONFIG_FILE.tmp
  mv $EXTRA_MOZCONFIG_FILE.tmp $B2G_DIR/gonk-misc/default-gecko-config
}

checkout() {
  reportStage Checkout

  cleanBeforeCheckout

  # Sync with the remote repository
  cd $B2G_DIR
  ./repo sync

  cleanAfterCheckout
}

checkoutByGeckoRev() {
  if test -z "$2"; then
    reportStage "Checkout By Gecko Sha1 ($1)"
  fi

  cleanBeforeCheckout

  # Checkout the defined version of Gecko
  cd $B2G_DIR/gecko
  git checkout "$1"

  # Synchronized other repositories with date of the latest commit of
  # gecko without updating gecko.
  cd $B2G_DIR
  ./repo sync --repo-date="gecko" /gecko

  cleanAfterCheckout
}

checkoutByGeckoChangeset() {
  # Get the date from a revision:
  #   git log -n 1 --pretty=format:%cd --date=iso $rev
  reportStage "Checkout By Gecko Changeset ($1)"

  checkoutByGeckoRev $(changesetToCommit "$1") false
}

clobber() {
  rm -rf $B2G_DIR/objdir-gecko $B2G_DIR/out || true
}

build() {
  reportStage Build
  cd $B2G_DIR

  # Failure proof building process:
  #   Build, build again, rebuild, update & try again …
  ./build.sh -j4 || \
      ./build.sh -j1 || \
      (rm -rf $B2G_DIR/objdir-gecko; ./build.sh -j4)
}

flash() {
  reportStage "Flash $ADB_FLAGS"
  cd $B2G_DIR
  test -n "$ADB_FLAGS" || find_device_name
  /bin/bash -x ./flash.sh $ADB_FLAGS
}

saveForLater() {
  local target="$1"
  test -e $target && rm $target;

  # Neutralize the paths for all scripts.  These scripts must be run
  # in the current directory.  This archive includes the symbols as it
  # only increate the size by 25%, and it is useful to have a
  # debuggable image.
  sed "s,$B2G_DIR,\$(pwd),g" $B2G_DIR/.config > $B2G_DIR/out/.config
  tar -cavf $target --show-transformed-names \
      -P --transform="s,$B2G_DIR,$(basename $B2G_DIR)," \
      $B2G_DIR/out/target/product/*/system/sources.xml \
      $B2G_DIR/out/target/product/*/*.img \
      $B2G_DIR/out/target/product/*/symbols \
      $B2G_DIR/objdir-gecko/dist/bin \
      --transform="s,out/.config,.config," \
      $B2G_DIR/flash.sh \
      $B2G_DIR/load-config.sh \
      $B2G_DIR/out/.config
}

setupHostForBenchmark() {
  reportStage Update Harness

  # Create install directory
  mkdir -p $INSTALL_DIR
  mkdir -p $INSTALL_DIR/lib/python2.7/site-packages

  # Install all marionette & gaia-ui-tests updates
  local setupPies="$(
      find $B2G_DIR/gecko/testing/ -name setup.py;
      find $B2G_DIR/$(cat $PERSO_SETUP_DIR/gaia-ui-tests.path)/gaia-ui-tests/ -name setup.py
  )"

  for path in $setupPies; do
      cd $(dirname $path);

      test -e ./requirements.txt && \
	  mv ./requirements.txt ./requirements.txt.old && \
	  sed  ./requirements.txt.old > ./requirements.txt '
            s/marionette_client==.*/marionette_client/;
            s/^\(moz.*\)[<=>][<=>][0-9.]*/\1/;
          '

      python setup.py develop --prefix=$INSTALL_DIR -N || true

      test -e ./requirements.txt && \
	  mv ./requirements.txt.old ./requirements.txt
  done
}

countRemoteHosts() {
  test "$(run_adb shell cat /etc/hosts | grep -c $1)" -eq $2
}

setupForBenchmark() {
  cd $SHARED_SETUP_DIR

  # wait for the device to appear under adb.
  run_adb wait-for-device

  # Restart Gecko processes, and reboot in order to reset the wifi
  # driver which are frequently failing unless the phone is fully
  # restarted.
  run_adb reboot
  run_adb wait-for-device

  # wait until the device can answer with the remote debugger
  # protocol.
  sleep 10

  # If We are using the awfy network then we need to set the address
  # of where the benchmarks are hosted, as we have a local copy of the
  # benchmarks which are hosted on a low-latency network.
  if test -e "$WIFINET" && test -n "$(cat "$WIFINET")"; then
      local netip=$(ip -o -4 addr list $(cat "$WIFINET") | awk '{print $4}' | cut -d/ -f1)
      if countRemoteHosts "$netip" 1 && countRemoteHosts people.mozilla.org 1; then
	  : # the file already contain the line, no need for updates.
      else
	  # Update the hosts file to redirect load.
	  run_adb shell 'mount -o remount,rw /system ; echo 127.0.0.1 localhost > /etc/hosts ; echo '"$netip"' people.mozilla.com >> /etc/hosts ; mount -o remount,ro /system'
      fi
  else
      # Reset the hosts file if we changed the network settings.
      if run_adb shell cat /etc/hosts | grep people.mozilla.org > /dev/null; then
	  run_adb shell 'mount -o remount,rw /system ; echo 127.0.0.1 localhost > /etc/hosts ; mount -o remount,ro /system'
      fi
  fi

  # Gecko opened the port 2828 on the phone, we listen on a local port
  # to forward connections of Marionette.
  local port=$(cat $LOCAL_PORT_FILE)
  run_adb forward tcp:$port tcp:2828

  # set performance governor on all cpus.
  for cpu in : $(run_adb shell 'ls /sys/devices/system/cpu/'); do
      case $cpu in
	  (cpu[0-9]) ;;
	  (*) continue;;
      esac
      run_adb shell "echo performance > /sys/devices/system/cpu/$cpu/cpufreq/scaling_governor"
  done
}

# Expect the benchmar directory
runBenchmark() {
  local bench=$1
  local port=$(cat $LOCAL_PORT_FILE)

  setupForBenchmark
  gaiatest \
    --address=127.0.0.1:$port --device=$FASTBOOT_SERIAL_NO \
    --testvars=$TESTVARS $bench
}

AWFY_DRIVER=$SHARED_SETUP_DIR/arewefastyet/driver/standalone.py

benchAndUpload() {
  local engine=$(cat $AWFY_ENGINE_FILE)

  reportStage Benchmark and Upload
  setupForBenchmark
  python $AWFY_DRIVER $(info) $AWFY_CONFIG  $engine $B2G_DIR 2>&1 | tee
}

benchAndPrint() {
  local engine=$(cat $AWFY_ENGINE_FILE)

  reportStage Benchmark and Print
  setupForBenchmark
  python $AWFY_DRIVER $(info) $LOCAL_AWFY_CONFIG $engine $B2G_DIR 2>&1 | tee
}

geckoGitInfo() {
  GIT_DIR=$B2G_DIR/gecko/.git git rev-parse HEAD
}

info() {
  geckoGit=$(geckoGitInfo)

  # The git-hg-bridge of hydra provides a command to convert git sha1
  # into mercurial changeset. It is easier for Gecko's developers to
  # deal with mercurial changeset.
  commitToChangeset "$geckoGit"
}

##
## Shortcuts for hand-made and for Are We Fast Yet builds
##
all() {
  checkout
  build
  flash
  benchmark
}

BROWSER_BENCHMARK=$GAIA_UI_TESTS/gaiatest/tests/browser/benchmarks
octane() {
  reportStage Run Octane
  runBenchmark $BROWSER_BENCHMARK/test_bench_octane.py
}

octane2() {
  reportStage Run Octane 2.0
  runBenchmark $BROWSER_BENCHMARK/test_bench_octane2.py
}

sunspider() {
  reportStage Run Sunspider
  runBenchmark $BROWSER_BENCHMARK/test_bench_sunspider.py
}

kraken() {
  reportStage Run Kraken
  runBenchmark $BROWSER_BENCHMARK/test_bench_kraken.py
}

benchmarkAll() {
  reportStage Run All Benchmarks
  runBenchmark $BROWSER_BENCHMARK/
}

update() {
  previous=$(geckoGitInfo)
  checkout
  current=$(geckoGitInfo)
  if test "$previous" != "$current"; then
    echo "Gecko: Update Sucessful."
    true
  else
    echo "Gecko: No update found."
    false
  fi
}

canUploadBenchmarks=false
idle() {
  local isIdle=true
  local bisectFile=
  local bisectVCS=
  local checkoutStrategy=
  local lastGeckoWorktree=
  local bisectWithPatches=$B2G_DIR/.bisect-patches

  local hgBisectFile=$B2G_DIR/.bisect-gecko.hg
  local gitBisectFile=$B2G_DIR/.bisect-gecko.git
  local bisectRunTests=$B2G_DIR/.bisect-run-tests
  if test -e $hgBisectFile && test -n "$(cat "$hgBisectFile")"; then
    bisectVCS=hg;
    bisectFile=$hgBisectFile
    checkoutStrategy=checkoutByGeckoChangeset
  elif test -e $gitBisectFile && test -n "$(cat "$gitBisectFile")"; then
    bisectVCS=git;
    bisectFile=$gitBisectFile
    checkoutStrategy=checkoutByGeckoRev
  fi

  if test -n "$bisectVCS"; then
    isIdle=false;
    lastGeckoWorktree=$(geckoGitInfo)
    mkdir -p $B2G_DIR/bisect.gecko
    testRev=$(head -n 1 "$bisectFile")

    while true; do
      $checkoutStrategy "$testRev"

      # Apply series of patches to the different trees.
      applyPatches "$bisectWithPatches"

      # Build, flash, create an exportable image, and run the benchmarks.
      build || break
      flash || break
      canUploadBenchmarks=false
      saveForLater "$B2G_DIR/bisect.gecko/$bisectVCS-$testRev.xz"
      if test -e $bisectRunTests; then
        setupHostForBenchmark
        benchAndPrint || break
      fi
      break
    done 2>&1 | tee $B2G_DIR/bisect.gecko/$bisectVCS-$testRev.log
    sed -i '1 d' "$bisectFile"

    # Undo the modifications made by the patches.
    undoPatches "$bisectWithPatches"

    # Restore the repository to its original state.
    checkoutByGeckoRev "$lastGeckoWorktree" false
  fi

  if $isIdle; then
    echo "$$: Wait for modifications"
    if $canUploadBenchmarks; then
      setupHostForBenchmark
      benchAndUpload
    else
      sleep 300
    fi
  fi
}

loop() {
  while true; do
    echo "$$: Start Build & Bench process"
    if update || test \! -e $B2G_DIR/out; then
      canUploadBenchmarks=false
      build || continue
      flash || continue
      canUploadBenchmarks=true
      # Save an image of the last build.
      saveForLater "$B2G_DIR/out/git-lastest.xz" >/dev/null &
      setupHostForBenchmark
      benchAndUpload
    else
      idle
    fi
  done
}

idleloop() {
  while true; do
    idle
  done
}

##
## Call the function which name is given as argument.
##
if test "$1" = checkoutByGeckoChangeset -o "$1" = saveForLater -o "$1" = changesetToCommit -o "$1" = commitToChangeset; then
  # Used for testing.
  "$@";
else
  for arg; do
    $arg ;
  done
fi
