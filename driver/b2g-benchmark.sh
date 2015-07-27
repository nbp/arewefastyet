#!/bin/sh

B2G_DIR=${B2G_DIR:-/home/awsa/unagi/B2G}
if test -d "$1"; then
    B2G_DIR=$1
    shift;
fi

# define DEVICE_NAME
. "$B2G_DIR/.config"

export ANDROIDFS_DIR=$(dirname $B2G_DIR)/backup-${DEVICE_NAME}

SHARED_SETUP_DIR=${SHARED_SETUP_DIR-/home/awsa}
PERSO_SETUP_DIR=${PERSO_SETUP_DIR:-$B2G_DIR/perso}

# Needed by gaia-ui-tests
GAIA_UI_TESTS=$PERSO_SETUP_DIR/gaia-ui-tests
INSTALL_DIR=$PERSO_SETUP_DIR/.usr
export PYTHONPATH=$INSTALL_DIR/lib/python2.7/site-packages:
export PATH=$INSTALL_DIR/bin:$PATH

# Python keeps writting bytecode, and installing/using either outdated versions
# Prevent the generation of any bytecode by exporting the following env var.
export PYTHONDONTWRITEBYTECODE=1


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
    local chgset=$1
    local commit=$(curl 'https://api.pub.build.mozilla.org/mapper/gecko-dev/rev/hg/'"$chgset" |\
                   sed -n '/\([^ ]*\) '"$chgset"'[^ ]*/ { s//\1/; p; Q }')
    if test -z "$commit" ; then
	commit="hg-$1"
    fi
    echo "$commit"
}

commitToChangeset() {
    local commit=$1
    local chgset=$(curl 'https://api.pub.build.mozilla.org/mapper/gecko-dev/rev/git/'"$commit" |\
                          sed -n '/'"$commit"'[^ ]* \([^ ]*\)/ { s//\1/; p; Q }')
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
SYS_DEVICE_LNK=$PERSO_SETUP_DIR/out/sys-device

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

      # The device is found by adb, then make a symbolic link to where
      # is is located on the bus system.
      if test \! -e $SYS_DEVICE_LNK -o \
	      "$(cat $SYS_DEVICE_LNK/serial 2>/dev/null)" != "$FASTBOOT_SERIAL_NO"
      then
	  local sys=$(find /sys -name serial | xargs grep -l $FASTBOOT_SERIAL_NO 2> /dev/null)
	  sys=$(dirname $sys)
	  rm $SYS_DEVICE_LNK || true
	  mkdir -p $(dirname $SYS_DEVICE_LNK)
	  ln -s $sys $SYS_DEVICE_LNK
      fi
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
TESTVARS=${TESTVARS:-$SHARED_SETUP_DIR/bench-testvars.json}

WIFINET=$SHARED_SETUP_DIR/wifi.server.network

# This configuration file inform the standalone driver of AWFY how to
# upload results.
AWFY_CONFIG=$PERSO_SETUP_DIR/awfy.config
LOCAL_AWFY_CONFIG=$PERSO_SETUP_DIR/.awfy-local.config

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
    sed -f $PERSO_SETUP_DIR/update-manifest.sed $DEVICE_NAME.xml > awsa-$DEVICE_NAME.xml
    for base in : base-*.xml; do
      test -e $base || continue;
      sed -f $PERSO_SETUP_DIR/update-manifest.sed $base > awsa-$base
    done
    ln -sf $B2G_DIR/.repo/manifests/awsa-$DEVICE_NAME.xml $B2G_DIR/.repo/manifest.xml
    cd -
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

FETCH_LOCK=$PERSO_SETUP_DIR/fetch.lock
fetch() {
  (
    # If the lock exists, then return.
    flock -n 4 || return;

    # Pull repository changes.
    cd $B2G_DIR/.repo/manifests
    git pull
    updateManifest

    # Get changes from remote repositories
    cd $B2G_DIR
    ionice -c 2 -n 7 ./repo sync --network-only --current-branch

  ) 4> $FETCH_LOCK
}

canPull() {
  flock -n 5 5> $FETCH_LOCK
}

pull() {
  # Sync with the remote repository
  cd $B2G_DIR
  ./repo sync --local-only
}

cleanBeforeCheckout() {
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

# Update all other repositories based on the current Gecko changeset.
# Even if timestamps are not reliable, we are still using them to find
# a more-less good revision which correspond to the time frame.
updateOthersBasedOnGecko() {
  cd $B2G_DIR
  ./repo sync --local-only --repo-date="gecko" /gecko
}

checkout() {
  reportStage Checkout

  cleanBeforeCheckout
  pull
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
  updateOthersBasedOnGecko

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

oneSlowBuild() {
  reportStage Slow Build
  cd $B2G_DIR

  ./build.sh -j1
}

clobberBuild() {
  reportStage Clobber Build
  cd $B2G_DIR

  rm -rf $B2G_DIR/objdir-gecko;
  ./build.sh
}

slowBuild() {
  reportStage Slow Build
  cd $B2G_DIR

  ./build.sh -j1 || clobberBuild
}

build() {
  reportStage Build
  cd $B2G_DIR

  # Failure proof building process:
  #   Build, build again, rebuild, update & try again …
  ./build.sh || slowBuild
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
  rm -rf $INSTALL_DIR
  mkdir -p $INSTALL_DIR
  mkdir -p $INSTALL_DIR/lib/python2.7/site-packages

  # Install all marionette & gaia-ui-tests updates
  local setupPies="$(
      find $B2G_DIR/perso/python-libraries/ -name setup.py
      find $B2G_DIR/gecko/testing/ -name setup.py;
      find $B2G_DIR/$(cat $PERSO_SETUP_DIR/gaia-ui-tests.path)/gaia-ui-tests/ -name setup.py
  )"

  for path in $setupPies; do
      cd $(dirname $path);

      # Somebody thought this was a good idea to name a file setup.py,  but
      # not for installing any python software.  This lines filter any script
      # which does not import a setup function.
      if ! grep 'import setup' ./setup.py 2>/dev/null </dev/null; then
          continue;
      fi

      if test -e ./requirements.txt; then
          cat ./requirements.txt
	  mv ./requirements.txt ./requirements.txt.old
	  sed '
            s/^\(marionette.*\)[<=>][<=>]\([0-9.]*\)/\1>=\2/;
            s/^\(moz.*\)[<=>][<=>][0-9.]*/\1/;
          ' ./requirements.txt.old > ./requirements.txt
          cat ./requirements.txt
      fi

      while true; do
          python setup.py develop --prefix=$INSTALL_DIR -N && break || true;
	  python setup.py install --prefix=$INSTALL_DIR && break || true;

          # Some error are caused by the fact that the requirement
          # file no longer have any version filter.  Copy the old
          # file, and test again.
	  mv ./requirements.txt.old ./requirements.txt
          python setup.py develop --prefix=$INSTALL_DIR -N && break || true;
	  python setup.py install --prefix=$INSTALL_DIR && break || true;

	  reportStage !!! Unable to install $path
	  exit 1;
      done

      if test -e ./requirements.txt; then
	  mv ./requirements.txt.old ./requirements.txt
      fi

      echo $path Installed
  done
}

countRemoteHosts() {
  test "$(run_adb shell cat /etc/hosts | grep -c $1)" -eq $2
}

rebootForBenchmark() {
  # Restart Gecko processes, and reboot in order to reset the wifi
  # driver which are frequently failing unless the phone is fully
  # restarted.
  run_adb reboot
  sleep 5

  # Wait until adb can answer
  run_adb wait-for-device

  # wait until the device can answer with the remote debugger
  # protocol.
  sleep 10
}

setupForBenchmark() {
  cd $SHARED_SETUP_DIR

  # wait for the device to appear under adb.
  run_adb wait-for-device

  # Ensure that all the shells have root priviledges.
  run_adb root || true

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

  # while test 0 -eq "$(run_adb shell b2g-ps | grep -c Homescreen)"; do
  #   sleep 10
  # done
}

# Expect the benchmar directory
runBenchmark() {
  local bench=$1
  local port=$(cat $LOCAL_PORT_FILE)

  rebootForBenchmark
  setupForBenchmark
  gaiatest \
    --address=127.0.0.1:$port --device=$FASTBOOT_SERIAL_NO \
    --testvars=$TESTVARS $bench
  # --restart
}

AWFY_DRIVER=$SHARED_SETUP_DIR/arewefastyet/driver/standalone.py

benchAndUpload() {
  local engine=$(cat $AWFY_ENGINE_FILE)
  local extraInfo=$(awfyExtraInfo)

  reportStage Benchmark and Upload
  setupForBenchmark
  python $AWFY_DRIVER $(info) $AWFY_CONFIG  $engine $B2G_DIR "$extraInfo" 2>&1 | tee
}

benchAndPrint() {
  local engine=$(cat $AWFY_ENGINE_FILE)
  local extraInfo=$(awfyExtraInfo)

  reportStage Benchmark and Print
  setupForBenchmark
  sed 's/local=no/local=yes/' $AWFY_CONFIG > $LOCAL_AWFY_CONFIG
  python $AWFY_DRIVER $(info) $LOCAL_AWFY_CONFIG $engine $B2G_DIR "$extraInfo" 2>&1 | tee
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

# Use git-repo to spew the Sha1 of all commits which are checked out.
allRepoInfo() {
    ./repo manifest -ro -
}

# Summarize the git-repo info to only include gecko and gaia git commits, and
# format the output in a single line which can also be interpreted both as a
# json / python.
awfyExtraInfo() {
    allRepoInfo | awk '
      BEGIN { str=""; }
      /gaia|gecko/ {
          rev[0] = "";
          name[0] = "";
          split($0, rev, "revision=");
          split(rev[2], rev);
          split($0, name, "path=");
          if (length(name) != 2)
              split($0, name, "name=");
          split(name[2], name);
          str = (str ? str "," : "") name[1] ":" rev[1];
      }
      END { print("{" str "}"); }
    '
}

##
## Shortcuts for hand-made and for Are We Fast Yet builds
##
all() {
  fetch
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

  if false; then
      cat <<EOF
Shell-like octane results:
Richards: 1060
DeltaBlue: 3154
Crypto: 2332
RayTrace: 6197
EarleyBoyer: 2404
RegExp: 238
Splay: 686
SplayLatency: 831
NavierStokes: 2835
PdfJS: 963
Mandreel: 1516
MandreelLatency: 1318
Gameboy: 2412
CodeLoad: 1716
Box2D: 1771
zlib: 5451
Typescript: 1974
Score: 1680
End of shell-like results.
EOF
      return
  fi

  runBenchmark $BROWSER_BENCHMARK/test_bench_octane2.py
}

sunspider() {
  reportStage Run Sunspider

  if false; then
      cat <<EOF
Shell-like sunspider results:
===============================================
RESULTS (means and 95% confidence intervals)
-----------------------------------------------
Total:                       19761.2ms +/- 4.2%
-----------------------------------------------
  ai:                         1668.0ms +/- 5.3%
    astar:                    1668.0ms +/- 5.3%
  audio:                      8853.2ms +/- 8.9%
    beat-detection:           2013.0ms +/- 24.2%
    dft:                      3496.8ms +/- 6.0%
    fft:                      1509.0ms +/- 27.0%
    oscillator:               1834.4ms +/- 20.4%
  imaging:                    4160.8ms +/- 0.8%
    gaussian-blur:            1517.2ms +/- 0.6%
    darkroom:                 1058.2ms +/- 1.7%
    desaturate:               1585.4ms +/- 0.8%
  json:                       1227.2ms +/- 16.2%
    parse-financial:           662.0ms +/- 44.5%
    stringify-tinderbox:       565.2ms +/- 25.6%
  stanford:                   3852.0ms +/- 4.7%
    crypto-aes:                857.6ms +/- 6.1%
    crypto-ccm:               1131.8ms +/- 16.5%
    crypto-pbkdf2:            1299.6ms +/- 1.3%
    crypto-sha256-iterative:   563.0ms +/- 6.6%

End of shell-like results.
EOF
      return
  fi

  runBenchmark $BROWSER_BENCHMARK/test_bench_sunspider.py
}

kraken() {
  reportStage Run Kraken

  if false; then
      cat <<EOF
Shell-like kraken results:
===============================================
RESULTS (means and 95% confidence intervals)
-----------------------------------------------
Total:                       19761.2ms +/- 4.2%
-----------------------------------------------
  ai:                         1668.0ms +/- 5.3%
    astar:                    1668.0ms +/- 5.3%
  audio:                      8853.2ms +/- 8.9%
    beat-detection:           2013.0ms +/- 24.2%
    dft:                      3496.8ms +/- 6.0%
    fft:                      1509.0ms +/- 27.0%
    oscillator:               1834.4ms +/- 20.4%
  imaging:                    4160.8ms +/- 0.8%
    gaussian-blur:            1517.2ms +/- 0.6%
    darkroom:                 1058.2ms +/- 1.7%
    desaturate:               1585.4ms +/- 0.8%
  json:                       1227.2ms +/- 16.2%
    parse-financial:           662.0ms +/- 44.5%
    stringify-tinderbox:       565.2ms +/- 25.6%
  stanford:                   3852.0ms +/- 4.7%
    crypto-aes:                857.6ms +/- 6.1%
    crypto-ccm:               1131.8ms +/- 16.5%
    crypto-pbkdf2:            1299.6ms +/- 1.3%
    crypto-sha256-iterative:   563.0ms +/- 6.6%

End of shell-like results.
EOF
      return
  fi

  runBenchmark $BROWSER_BENCHMARK/test_bench_kraken.py
}

benchmarkAll() {
  reportStage Run All Benchmarks
  runBenchmark $BROWSER_BENCHMARK/
}

update() {
  previous=$(geckoGitInfo)
  canPull && checkout
  current=$(geckoGitInfo)
  if test "$previous" != "$current"; then
    echo "Gecko: Update Sucessful."
    true
  else
    echo "Gecko: No update found."
    fetch > /dev/null &
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
      sleep 30
    fi
  fi
}

bisectStep () {
  reportStage Bisecting Step

  local bisectWithPatches=$B2G_DIR/.bisect/patches
  local bisectLog=$B2G_DIR/.bisect/log.txt
  while true; do
    exitCode=0

    # Save the bisection log.
    GIT_DIR=$B2G_DIR/gecko/.git git bisect log > $bisectLog

    # Synchronized based on the current version of Gecko.
    updateOthersBasedOnGecko || exitStep

    # Apply series of patches to the different trees.
    cleanAfterCheckout || exitStep
    applyPatches "$bisectWithPatches" || exitStep

    build || exitStep
    flash || exitStep

    # Archive the image of this build, in order to reproduce it later.
    testRev=$(geckoGitInfo)
    saveForLater "$B2G_DIR/.bisect/images/gecko-git-$testRev.xz" >/dev/null

    setupHostForBenchmark || exitStep

    bisectRunTests
    break;
  done 2>&1 | tee "$B2G_DIR/.bisect/images/gecko-git-$testRev.log"
}

bisectRunTests() {
  local bisectRunTests=$B2G_DIR/.bisect/run-tests

  exitCode=0
  "$bisectRunTests" "$0" "$B2G_DIR" || exitCode=$?
  exitStep
}

# If we cannot build / setup the phone correctly, then skip this
# revision by returning the exit code 125.  This exit code is a
# special exit code expected by "git bisect run" to skip the current
# revision and try another adjacent commit.
exitCode=125

exitStep() {
  # Undo the modifications made by the patches.
#  undoPatches "$bisectWithPatches" || exit $exitCode
#  cleanBeforeCheckout || exit $exitCode

  exit $exitCode
}


bisect() {
  local badFile=
  local goodFile=
  local bisectVCS=

  local bisectWithPatches=$B2G_DIR/.bisect/patches
  local gitBadRevFile=$B2G_DIR/.bisect/gecko.bad
  local gitGoodRevFile=$B2G_DIR/.bisect/gecko.good
  local bisectRunTests=$B2G_DIR/.bisect/run-tests
  local bisectLog=$B2G_DIR/.bisect/log.txt
  mkdir -p "$B2G_DIR/.bisect/images/"
  if test -e $gitGoodRevFile && test -n "$(cat "$gitGoodRevFile")"; then
    bisectVCS=git;
    badFile=$gitBadRevFile
    bisectFile=$gitGoodRevFile
    checkoutStrategy=checkoutByGeckoRev
  else
    echo 1>&2 "Mercurial is not supported yet."
    exit 1
  fi

  if \! test -x $bisectRunTests -a -f $bisectRunTests; then
    echo 1>&2 "Test case $bisectRunTests cannot be executed."
    exit 1
  fi

  if test -n "$bisectVCS"; then
    isIdle=false;
    lastGeckoWorktree=$(geckoGitInfo)
    mkdir -p $B2G_DIR/bisect.gecko
    testRev=$(head -n 1 "$bisectFile")

    cleanBeforeCheckout

    cd $B2G_DIR/gecko
    git bisect start
    git bisect good $(cat "$gitGoodRevFile")
    if test -e $gitBadRevFile && test -n "$(cat "$gitBadRevFile")"; then
      git bisect bad $(cat "$gitBadRevFile")
    else
      git bisect bad
    fi

    git bisect run "$0" "$B2G_DIR" bisectStep
    git bisect log > $bisectLog
    git bisect reset
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
      # Start fetching remote sources in parallel as benchmarking does
      # not require a lot of I/O.
      fetch > /dev/null &
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
call() {
  set -x
  "$@"
}

if test "$1" = checkoutByGeckoChangeset -o "$1" = saveForLater -o "$1" = changesetToCommit -o "$1" = commitToChangeset -o "$1" = call -o "$1" = runBenchmark; then
  # Used for testing.
  "$@";
else
  for arg; do
    $arg ;
  done
fi
