# vim: set ts=4 sw=4 tw=99 et:
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import os
import sys
import commands
import subprocess
import signal
import ConfigParser
import urllib
import tarfile
import zipfile
import stat

class ConfigState:
    def __init__(self):
        self.inited = False
        self.rawConfig = None
        self.RepoPath = None
        self.BenchmarkPath = None
        self.DriverPath = None
        self.Timeout = 15*60
        self.PythonName = None
        self.SlaveType = None

    def init(self, name):
        self.rawConfig = ConfigParser.RawConfigParser()
        if not os.path.isfile(name):
            raise Exception('could not find file: ' + name)
        self.rawConfig.read(name)
        self.inited = True

        self.RepoPath = self.get('main', 'repos')
        self.BenchmarkPath = self.get('benchmarks', 'dir')
        self.DriverPath = self.getDefault('main', 'driver', os.getcwd())
        self.Timeout = self.getDefault('main', 'timeout', str(15*60))
        self.Timeout = eval(self.Timeout, {}, {}) # silly hack to allow 30*60 in the config file.
        self.PythonName = self.getDefault(name, 'python', sys.executable)
        self.SlaveType = self.getDefault("main", 'slaveType', "")

    def get(self, section, name):
        assert self.inited
        return self.rawConfig.get(section, name)

    def getDefault(self, section, name, default):
        assert self.inited
        if self.rawConfig.has_option(section, name):
            return self.rawConfig.get(section, name)
        return default

    @staticmethod
    def parseBenchmarks(li):
        benchmarks = []
        for benchmark in li.split(","):
            benchmark = benchmark.strip()
            _, section, name = benchmark.split(".")
            if section == "local":
                import benchmarks_local
                benchmarks.append(benchmarks_local.getBenchmark(name))
            elif section == "remote":
                import benchmarks_remote
                benchmarks.append(benchmarks_remote.getBenchmark(name))
            elif section == "shell":
                import benchmarks_shell
                benchmarks.append(benchmarks_shell.getBenchmark(name))
            else:
                raise Exception("Unknown benchmark type")
        return benchmarks

    def browserbenchmarks(self):
        assert self.inited

        browserList = self.getDefault("benchmarks", "browserList", None)
        if not browserList:
            return []
        return ConfigState.parseBenchmarks(browserList)

    def shellbenchmarks(self):
        assert self.inited

        shellList = self.getDefault("benchmarks", "shellList", None)
        if not shellList:
            return []
        return ConfigState.parseBenchmarks(shellList)

    def engines(self):
        assert self.inited

        engineList = self.getDefault("engines", "list", None)
        if not engineList:
            return []

        import engine
        engines = []
        for engineName in engineList.split(","):
            engineName = engineName.strip()
            engines.append(engine.getEngine(engineName))
        return engines

config = ConfigState()

class FolderChanger:
    def __init__(self, folder):
        self.old = os.getcwd()
        self.new = folder

    def __enter__(self):
        os.chdir(self.new)

    def __exit__(self, type, value, traceback):
        os.chdir(self.old)

def chdir(folder):
    return FolderChanger(folder)

def Run(vec, env = os.environ.copy()):
    print(">> Executing in " + os.getcwd())
    print(' '.join(vec))
    print("with: " + str(env))
    try:
        o = subprocess.check_output(vec, stderr=subprocess.STDOUT, env=env)
    except subprocess.CalledProcessError as e:
        print 'output was: ' + e.output
        print e
        raise e
    o = o.decode("utf-8")
    print(o)
    return o

def Shell(string):
    print(string)
    status, output = commands.getstatusoutput(string)
    print(output)
    return output

class TimeException(Exception):
    pass
def timeout_handler(signum, frame):
    raise TimeException()
class Handler():
    def __init__(self, signum, lam):
        self.signum = signum
        self.lam = lam
        self.old = None
    def __enter__(self):
        self.old = signal.signal(self.signum, self.lam)
    def __exit__(self, type, value, traceback):
        signal.signal(self.signum, self.old)


def RunTimedCheckOutput(args, env = os.environ.copy(), timeout = None, **popenargs):
    if timeout is None:
        timeout = config.Timeout
    print('Running: "'+ '" "'.join(args) + '" with timeout: ' + str(timeout)+'s')
    p = subprocess.Popen(args, env = env, stdout=subprocess.PIPE, **popenargs)
    with Handler(signal.SIGALRM, timeout_handler):
        try:
            signal.alarm(timeout)
            output = p.communicate()[0]
            # if we get an alarm right here, nothing too bad should happen
            signal.alarm(0)
            if p.returncode:
                print "ERROR: returned" + str(p.returncode)
        except TimeException:
            # make sure it is no longer running
            p.kill()
            # in case someone looks at the logs...
            print ("WARNING: Timed Out")
            # try to get any partial output
            output = p.communicate()[0]
    print (output)
    return output


def unzip(directory, name):
    if "tar.bz2" in name:
        tar = tarfile.open(directory + "/" + name)
        tar.extractall(directory + "/")
        tar.close()
    else:
        zip = zipfile.ZipFile(directory + "/" + name)
        zip.extractall(directory + "/")
        zip.close()

def chmodx(file):
    st = os.stat(file)
    os.chmod(file, st.st_mode | stat.S_IEXEC)

def getOrDownload(directory, prefix, revision, file, output):
    rev_file = directory + "/" + prefix + "-revision"
    old_revision = ""
    if os.path.isfile(rev_file):
        fp = open(rev_file, 'r')
        old_revision = fp.read()
        fp.close()

    if revision != old_revision:
        print "Retrieving", file
        urllib.urlretrieve(file, output)

        fp = open(rev_file, 'w')
        fp.write(revision)
        fp.close()

