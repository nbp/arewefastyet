import json
import sys
import urllib2
import urllib
import re
import subprocess
import os
import stat
import shutil
import signal
import time
import socket
socket.setdefaulttimeout(120)

sys.path.insert(1, '../driver')
import utils

class TimeException(Exception):
    pass
def timeout_handler(signum, frame):
    raise TimeException()

class Engine:
    def __init__(self):
        self.updated = False
        self.tmp_dir = utils.config.get('main', 'tmpDir')
        self.slaveType = utils.config.get('main', 'slaveType')

    def kill(self):
        self.subprocess.terminate()

        for i in range(100):
            time.sleep(0.1)
            if self.subprocess.poll():
                return
            time.sleep(0.1)

        try:
            os.kill(int(self.pid), signal.SIGTERM)
        except:
            pass

class Mozilla(Engine):
    def __init__(self):
        Engine.__init__(self)
        self.nightly_dir = utils.config.get('mozilla', 'nightlyDir')
        self.isBrowser = True
        self.modes = [{
            'name': 'jmim',
            'env': { 'JSGC_DISABLE_POISONING': '1' }
        }]
        self.folder = "firefox"
        if not os.path.isdir(self.tmp_dir + self.folder):
            os.mkdir(self.tmp_dir + self.folder)

    def update(self):
        # Step 0: Make sure folder exists.
        if not os.path.exists(self.tmp_dir+"/"+self.folder):
            os.makedirs(self.tmp_dir+"/"+self.folder)

        # Step 1: Get newest nightly folder
        if "latest" in self.nightly_dir:
            self._update(".")
        else:
            response = urllib2.urlopen(self.nightly_dir+"/?C=N;O=D")
            html = response.read()
            ids = re.findall("[0-9]{5,}", html)

            for folder_id in ids[0:4]:
                try:
                    print "trying", folder_id
                    self._update(folder_id)
                except Exception, e:
                    import logging
                    logging.exception(e) # or pass an error message, see comment
                    continue
                break

    def _update(self, folder_id):
        # Step 2: Find the correct file
        response = urllib2.urlopen(self.nightly_dir+"/"+folder_id)
        html = response.read()
        if self.slaveType == "android":
            exec_file = re.findall("fennec-[a-zA-Z0-9.]*.en-US.android-arm.apk", html)[0]
            json_file = re.findall("fennec-[a-zA-Z0-9.]*.en-US.android-arm.json", html)[0]
        elif self.slaveType == "mac-desktop":
            exec_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.mac.dmg", html)[0]
            json_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.mac.json", html)[0]
        elif self.slaveType == "linux-desktop":
            exec_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.linux-x86_64.tar.bz2", html)[0]
            json_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.linux-x86_64.json", html)[0]
        else:
            exec_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.win32.zip", html)[0]
            json_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.win32.json", html)[0]

        # Step 3: Get build information
        response = urllib2.urlopen(self.nightly_dir+"/"+folder_id+"/"+json_file)
        html = response.read()
        info = json.loads(html)

        # Step 4: Test if there is a new revision
        if self.slaveType == "android":
            output = self.tmp_dir + self.folder + "/fennec.apk"
        elif self.slaveType == "mac-desktop":
            output = self.tmp_dir + self.folder + "/firefox.dmg"
        elif self.slaveType == "linux-desktop":
            output = self.tmp_dir + self.folder + "/firefox.tar.bz2"
        else:
            output = self.tmp_dir + self.folder + "/firefox.zip"
        utils.getOrDownload(self.tmp_dir, "mozilla", info["moz_source_stamp"],
                            self.nightly_dir + "/" + folder_id + "/" + exec_file,
                            output)

        # Step 5: Prepare to run
        if self.slaveType == "android":
            print subprocess.check_output(["adb", "install", "-r", self.tmp_dir + self.folder + "/fennec.apk"])
        elif self.slaveType == "mac-desktop":
            if os.path.exists("/Volumes/Nightly"):
                print subprocess.check_output(["hdiutil", "detach", "/Volumes/Nightly"])
            print subprocess.check_output(["hdiutil", "attach", self.tmp_dir + self.folder + "/firefox.dmg"])
        elif self.slaveType == "linux-desktop":
            utils.unzip(self.tmp_dir + self.folder, "firefox.tar.bz2")
        else:
            utils.unzip(self.tmp_dir + self.folder, "firefox.zip")

        # Step 6: Save info
        self.updated = True
        self.cset = info["moz_source_stamp"]

    def runAndroid(self, page, mode):
        # To be sure.
        self.kill()

        # Remove profile
        print subprocess.check_output(["adb", "shell", "rm -rf /storage/emulated/legacy/awfy"])

        # Create profile and disable slow script dialog
        print subprocess.check_output(["adb", "shell", "mkdir /storage/emulated/legacy/awfy"])
        print subprocess.check_output(["adb", "shell", "echo 'user_pref(\"dom.max_script_run_time\", 0);' > /storage/emulated/legacy/awfy/prefs.js"])

        # Create env
        parsedenv = ""
        i = 0
        for env in mode["env"]:
            parsedenv += "--es env"+str(i)+" "+env+"="+mode["env"][env]+" "
            i += 0

        # Start browser
        print subprocess.check_output(["adb", "shell", "am start -a android.intent.action.VIEW -n org.mozilla.fennec/.App -d "+page+" "+parsedenv+" --es args \"--profile /storage/emulated/legacy/awfy\""])

    def runDesktop(self, page, mode):
        if self.slaveType == "mac-desktop":
            executable = "/Volumes/Nightly/Nightly.app/Contents/MacOS/firefox"
        elif self.slaveType == "linux-desktop":
            executable = self.tmp_dir + self.folder + "/firefox/firefox"
        else:
            executable = self.tmp_dir + self.folder + "/firefox/firefox.exe"

        # Step 2: Delete profile
        if os.path.exists(self.tmp_dir + "profile"):
            shutil.rmtree(self.tmp_dir + "profile")

        # Step 3: Create new profile
        output = subprocess.check_output([executable,
                                         "-CreateProfile", "test "+self.tmp_dir+"profile"],
                                         stderr=subprocess.STDOUT)

        # Step 4: Disable slow script dialog
        fp = open(self.tmp_dir + "profile/prefs.js", 'w')
        fp.write('user_pref("dom.max_script_run_time", 0);');
        fp.close()

        # Step 5: Start browser
        env = os.environ.copy()
        if "env" in mode:
            env.update(mode["env"])
        self.subprocess = subprocess.Popen([executable,
                                           "-P", "test", page], env=env)
        self.pid = self.subprocess.pid

    def run(self, page, mode):
        if self.slaveType == "android":
            self.runAndroid(page, mode)
        else:
            self.runDesktop(page, mode)

    def kill(self):
        if self.slaveType == "android":
            print subprocess.check_output(["adb", "shell", "pm", "clear", "org.mozilla.fennec"]);
        elif self.slaveType == "linux-desktop":
            subprocess.Popen(["killall", "plugin-container"])
            Engine.kill(self)
        else:
            Engine.kill(self)

class MozillaPGO(Mozilla):
    def __init__(self):
        Mozilla.__init__(self)
        self.nightly_dir = utils.config.get('mozilla', 'pgoDir')
        self.modes = [{
            'name': 'pgo'
        }]
        self.folder = "firefox-pgo"

class MozillaShell(Engine):
    def __init__(self):
        Engine.__init__(self)
        self.nightly_dir = utils.config.get('mozilla', 'nightlyDir')
        self.isShell = True
        self.modes = [{
            'name': 'mozshell',
            'args': []
        }]

    def update(self):
        # Step 1: Get newest nightly folder
        response = urllib2.urlopen(self.nightly_dir+"/?C=N;O=D")
        html = response.read()
        folder_id =  re.findall("[0-9]{5,}", html)[0]

        # Step 2: Find the correct file
        response = urllib2.urlopen(self.nightly_dir+"/"+folder_id)
        html = response.read()
        exec_file = re.findall("jsshell-win32.zip", html)[0]
        json_file = re.findall("firefox-[a-zA-Z0-9.]*.en-US.win32.json", html)[0]

        # Step 3: Get build information
        response = urllib2.urlopen(self.nightly_dir+"/"+folder_id+"/"+json_file)
        html = response.read()
        info = json.loads(html)

        # Step 4: Fetch archive
        print "Retrieving", self.nightly_dir+"/"+folder_id+"/"+exec_file
        urllib.urlretrieve(self.nightly_dir+"/"+folder_id+"/"+exec_file, self.tmp_dir + "shell.zip")

        # Step 5: Unzip
        utils.unzip(self.tmp_dir,"shell.zip")

        # Step 6: Save info
        self.updated = True
        self.cset = info["moz_source_stamp"]

    def run(self, page, mode):
        pass

    def shell(self):
        return os.path.join(self.tmp_dir,'js.exe')

    def env(self):
        return {"JSGC_DISABLE_POISONING": "1"}

class Chrome(Engine):
    def __init__(self):
        Engine.__init__(self)
        self.build_info_url = utils.config.get('chrome', 'buildInfoUrl')
        self.nightly_dir = utils.config.get('chrome', 'nightlyDir')
        self.isBrowser = True
        self.modes = [{
            'name': 'v8'
        }]
        if self.slaveType == "android":
            self.filename = "chrome-android.zip"
        elif self.slaveType == "mac-desktop":
            self.filename = "chrome-mac.zip"
        elif self.slaveType == "linux-desktop":
            self.filename = "chrome-linux.zip"
        else:
            self.filename = "chrome-win32.zip"

    def update(self):
        # Step 1: Get latest succesfull build revision
        response = urllib2.urlopen(self.nightly_dir+"LAST_CHANGE")
        chromium_rev = response.read()

        # Step 3: Get v8 revision
        response = urllib2.urlopen(self.nightly_dir + chromium_rev + "/REVISIONS")
        self.cset = re.findall('"v8_revision_git": "([a-z0-9]*)",', response.read())[0]

        # Step 3: Test if there is a new revision
        utils.getOrDownload(self.tmp_dir, "chrome", self.cset,
                            self.nightly_dir + chromium_rev + "/" + self.filename,
                            self.tmp_dir + self.filename)
        # Step 4: Unzip
        utils.unzip(self.tmp_dir, self.filename)

        # Step 5: Install on device
        if self.slaveType == "android":
            print subprocess.check_output(["adb", "install", "-r", self.tmp_dir+"/chrome-android/apks/ChromeShell.apk"])

        # Step 6: Save info
        self.updated = True

    def run(self, page, mode):
        if self.slaveType == "android":
            self.kill()
            print subprocess.check_output(["adb", "shell", "am start -a android.intent.action.VIEW -n org.chromium.chrome.shell/org.chromium.chrome.shell.ChromeShellActivity -d", page])
        elif self.slaveType == "mac-desktop":
            execs = subprocess.check_output(["find", self.tmp_dir + "chrome-mac", "-type", "f"])
            for i in execs.split("\n"):
                if "/Contents/MacOS/" in i:
                    utils.chmodx(i)
            self.subprocess = subprocess.Popen([self.tmp_dir + "chrome-mac/Chromium.app/Contents/MacOS/Chromium", page])
            self.pid = self.subprocess.pid
        elif self.slaveType == "linux-desktop":
            utils.chmodx(self.tmp_dir + "chrome-linux/chrome")
            self.subprocess = subprocess.Popen([self.tmp_dir + "chrome-linux/chrome", page])
            self.pid = self.subprocess.pid
        else:
            self.subprocess = subprocess.Popen([self.tmp_dir + "chrome-win32/chrome.exe", page])
            self.pid = self.subprocess.pid

    def kill(self):
        if self.slaveType == "android":
            print subprocess.check_output(["adb", "shell", "pm clear org.chromium.chrome.shell"]);
        else:
            Engine.kill(self)

class WebKit(Engine):
    def __init__(self):
        Engine.__init__(self)
        self.build_info_url = utils.config.get('webkit', 'buildInfoUrl')
        self.nightly_dir = utils.config.get('webkit', 'nightlyDir')
        self.isBrowser = True
        self.modes = [{
            'name': 'jsc'
        }]

    def update(self):
        # Step 1: Get latest succesfull build revision
        response = urllib2.urlopen(self.build_info_url)
        self.cset = re.findall('WebKit r([0-9]*)<', response.read())[0]

        # Step 2: Download the latest installation
        utils.getOrDownload(self.tmp_dir, "webkit", self.cset,
                            self.nightly_dir + "WebKit-SVN-r" + self.cset + ".dmg",
                            self.tmp_dir + "WebKit.dmg")

        # Step 3: Prepare running
        if os.path.exists("/Volumes/WebKit"):
            self.kill()
            print subprocess.check_output(["hdiutil", "detach", "/Volumes/WebKit"])
        print subprocess.check_output(["hdiutil", "attach", self.tmp_dir + "/WebKit.dmg"])

        # Step 4: Save info
        self.updated = True

    def run(self, page, mode):
        self.subprocess = subprocess.Popen(["open", "-F", "-a", "/Volumes/WebKit/WebKit.app/Contents/MacOS/WebKit", page])
        self.pid = self.subprocess.pid

    def kill(self):
        try:
            subprocess.check_output("kill $(ps aux | grep '/[V]olumes/WebKit/' | awk '{print $2}')", shell=True)
        except:
            pass
        try:
            subprocess.check_output("rm -Rf ~/Library/Saved\ Application\ State/com.apple.Safari.savedState", shell=True)
        except:
            pass

def getEngine(name):
    if name == "chrome":
        return Chrome()
    if name == "mozillapgo":
        return MozillaPGO()
    if name == "mozillashell":
        return MozillaShell()
    if name == "mozilla":
        return Mozilla()
    if name == "webkit":
        return WebKit()
    raise Exception("Unknown engine")
