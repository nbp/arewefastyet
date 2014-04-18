# vim: set ts=4 sw=4 tw=99 et:
import re
import urllib2

class Submitter:
    def __init__(self, conf):
        self.urls = conf.get('main', 'updateURL').split(",")
        self.machine = conf.get('main', 'machine')
        self.runIds = []
        for i in range(len(self.urls)):
            self.urls[i] = self.urls[i].strip()
            self.runIds.append(None)

    def Start(self):
        for i in range(len(self.urls)):
            try:
                url = self.urls[i]
                url += '?run=yes'
                url += '&MACHINE=' + str(self.machine)
                url = urllib2.urlopen(url)
                contents = url.read()
                m = re.search('id=(\d+)', contents)
                if m != None:
                    self.runIds[i] = int(m.group(1))
            except urllib2.URLError:
                pass

    def AddEngine(self, name, cset):
        for i in range(len(self.urls)):
            if not self.runIds[i]:
                continue
            
            url = self.urls[i]
            url += '?run=addEngine'
            url += '&runid=' + str(self.runIds[i])
            url += '&name=' + name
            url += '&cset=' + str(cset)
            urllib2.urlopen(url)

    def AddTests(self, tests, suite, mode):
        for test in tests:
            self.SubmitTest(test['name'], suite, mode, test['time'])

    def SubmitTest(self, name, suite, mode, time):
        for i in range(len(self.urls)):
            if not self.runIds[i]:
                continue
            
            url = self.urls[i]
            url += '?name=' + name
            url += '&run=' + str(self.runIds[i])
            url += '&suite=' + suite
            url += '&mode=' + mode
            url += '&time=' + str(time)
            urllib2.urlopen(url)

    def Finish(self, status):
        for i in range(len(self.urls)):
            if not self.runIds[i]:
                continue
            
            url = self.urls[i]
            url += '?run=finish'
            url += '&status=' + str(status)
            url += '&runid=' + str(self.runIds[i])
            urllib2.urlopen(url)

class FakeSubmitter:
    def __init__(self, conf):
        return

    def Start(self):
        self.lastSuite = None

    def AddEngine(self, name, cset):
        print "Engine: %s (%s):" % (name, str(cset))

    def AddTests(self, tests, suite, mode):
        for test in tests:
            self.SubmitTest(test['name'], suite, mode, test['time'])

    def SubmitTest(self, name, suite, mode, time):
        if suite != self.lastSuite:
            print "  Suite: %s (%s)" % (suite, mode)
            self.lastSuite = suite
        print "    %s:\t%s" % (name, str(time))

    def Finish(self, status):
        return
