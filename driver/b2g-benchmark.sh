#!/bin/sh

SETUP_DIR=/home/awsa
B2G_DIR=/home/awsa/unagi/B2G
TESTVARS=$SETUP_DIR/bench-testvars.json

# Needed by gaia-ui-tests
export PYTHONPATH=$SETUP_DIR/.usr/lib/python2.7/site-packages:$PYTHONPATH
export PATH=$PATH:$SETUP_DIR/.usr/bin



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

##
## Functions used to setup the environment
##
installGaiaTestDeps() {
    apt-get install python-setuptools
}

installGaiaTest() {
    cd $SETUP_DIR
    git clone https://github.com/nbp/gaia-ui-tests.git
    cd $SETUP_DIR/gaia-ui-tests
    python setup.py develop --prefix=$SETUP_DIR/.usr
}

##
## Functions used to wrap around the building process of B2G.
##
cleanBeforeCheckout() {
  # Pull repository changes.
  cd $B2G_DIR/.repo/manifests
  git pull
  sed -f ~/update-manifest.sed unagi.xml > awsa-unagi.xml

  # Clean-up any mess which might have been added by any commit modifying the sources.
  cd $B2G_DIR/gecko
  git reset --hard

  # Undo changes.
  cd $B2G_DIR/gaia
  git reset --hard
}

cleanAfterCheckout() {
  # The silence fall.
  # http://blog.ginzburgconsulting.com/wp-content/uploads/2013/02/silent.ogg
  # https://github.com/mozilla-b2g/gaia/commit/0ec2a2558cf41da4a2bf52bf6a550e5e2293602c
  find $B2G_DIR/gaia -name \*.ogg | xargs -n 1 cp ~/silent.ogg
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

  checkoutByGeckoRev $(ssh git@hydra changeset-to-commit "$1")
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
  reportStage Flash
  cd $B2G_DIR
  ./flash.sh
}

saveForLater() {
  local target="$1"
  cd $B2G_DIR/..
  tar cavf $target \
      $B2G_DIR/flash.sh \
      $B2G_DIR/load-config.sh \
      $B2G_DIR/out/target/product/*/system/sources.xml \
      $B2G_DIR/out/target/product/*/*.img
}

setupHostForBenchmark() {
  reportStage Update Harness

  # Install all marionette updates.
  find $B2G_DIR/gecko/testing/ -name setup.py | \
      while read path; do
          cd $(dirname $path);
	  python setup.py develop --prefix=$SETUP_DIR/.usr -N
      done

  # Update gaia-ui-tests
  cd $SETUP_DIR/gaia-ui-tests
  python setup.py develop --prefix=$SETUP_DIR/.usr -N
}

setupForBenchmark() {
  cd $SETUP_DIR

  # wait until the device can answer with the remote debugger
  # protocol.
  adb wait-for-device
  sleep 10

  # If We are using the awfy network then we need to set the address
  # of where the benchmarks are hosted.
  if test "$(readlink $TESTVARS)" = "$(basename $TESTVARS).awfy"; then
      if adb shell cat /etc/hosts | grep people.mozilla.org > /dev/null; then
	  : # the file already contain the line, no need for updates.
      else
	  # Append a redirect to the hosts file.
	  adb shell 'mount -o remount,rw /system ; echo 192.168.1.51 people.mozilla.com >> /etc/hosts ; mount -o remount,ro /system'
      fi
  else
      # Reset the hosts file if we changed the network settings.
      if adb shell cat /etc/hosts | grep people.mozilla.org > /dev/null; then
	  adb shell 'mount -o remount,rw /system ; echo 127.0.0.1 localhost > /etc/hosts ; mount -o remount,ro /system'
      fi
  fi

  # setup for the benchmark.
  adb forward tcp:2828 tcp:2828
  adb shell "echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
}

# Expect the benchmar directory
runBenchmark() {
  local bench=$1
  setupForBenchmark
  gaiatest \
    --address=127.0.0.1:2828 --device=full_unagi \
    --testvars=$TESTVARS $bench
}

benchAndUpload() {
  reportStage Benchmark and Upload
  setupForBenchmark
  python $SETUP_DIR/arewefastyet/driver/standalone.py $(info) '/home/awsa/awfy.config'
}

benchAndPrint() {
  reportStage Benchmark and Print
  setupForBenchmark
  python $SETUP_DIR/arewefastyet/driver/standalone.py $(info) '/home/awsa/awfy-local.config'
}

geckoGitInfo() {
  GIT_DIR=$B2G_DIR/gecko/.git git rev-parse HEAD
}

info() {
  geckoGit=$(geckoGitInfo)

  # The git-hg-bridge of hydra provides a command to convert git sha1
  # into mercurial changeset. It is easier for Gecko's developers to
  # deal with mercurial changeset.
  ssh git@hydra commit-to-changeset $geckoGit
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

octane() {
  reportStage Run Octane
  runBenchmark $SETUP_DIR/gaia-ui-tests/gaiatest/tests/browser/benchmarks/test_bench_octane.py
}

sunspider() {
  reportStage Run Sunspider
  runBenchmark $SETUP_DIR/gaia-ui-tests/gaiatest/tests/browser/benchmarks/test_bench_sunspider.py
}

kraken() {
  reportStage Run Kraken
  runBenchmark $SETUP_DIR/gaia-ui-tests/gaiatest/tests/browser/benchmarks/test_bench_kraken.py
}

benchmarkAll() {
  reportStage Run All Benchmarks
  runBenchmark $SETUP_DIR/gaia-ui-tests/gaiatest/tests/browser/benchmarks/
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

buildAndFlash() {
  rm -f $SETUP_DIR/.b2g-browser
  build
  flash
  cat - > $SETUP_DIR/.b2g-browser <<B2GBROWSER
#!/bin/sh

if test $(basename $(pwd)) == octane; then
  exec $BENCHMARK_SCRIPT octane
else
  exit 1
fi
B2GBROWSER
}

idle() {
  local isIdle=true
  local bisectFile=$B2G_DIR/.hgbisect-gecko
  if test -e $bisectFile && test -n "$(cat "$bisectFile")"; then
    isIdle=false;
    lastGeckoWorktree=$(geckoGitInfo)

    mkdir -p $B2G_DIR/bisect.gecko
    testRev=$(head -n 1 "$bisectFile")
    checkoutByGeckoChangeset "$testRev"
    while true; do
      build || break
      flash || break
      saveForLater "$B2G_DIR/bisect.gecko/hg-$testRev.xz"
      setupHostForBenchmark
      benchAndPrint || break
      break
    done 2>&1 | tee $B2G_DIR/bisect.gecko/hg-"$testRev".log
    sed -i '1 d' "$bisectFile"
    checkoutByGeckoRev "$lastGeckoWorktree"
  fi

  if $isIdle; then
    echo "$$: Wait for modifications"
    sleep 300
  fi
}

loop() {
  while true; do
    echo "$$: Start Build & Bench process"
    if update || test \! -e $B2G_DIR/out; then
      build || continue
      flash || continue
      setupHostForBenchmark
      benchAndUpload
    else
      idle
    fi
  done
}


if test "$1" = checkoutByGeckoChangeset -o "$1" = saveForLater; then
  # Used for testing.
  "$@";
else
  for arg; do
    $arg ;
  done
fi
