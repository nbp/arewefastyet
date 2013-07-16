# vim: set ts=4 sw=4 tw=99 et:
import re
import urllib2

class Submitter:
    def __init__(self, conf):
        self.url = conf.get('main', 'updateURL')
        self.machine = conf.get('main', 'machine')

    def Start(self):
        url = self.url
        url += '?run=yes'
        url += '&MACHINE=' + str(self.machine)
        url = urllib2.urlopen(url)
        contents = url.read()
        m = re.search('id=(\d+)', contents)
        if m == None:
            raise Exception('Remote error: ' + contents)
        self.runID = int(m.group(1))

    def AddEngine(self, name, cset):
        url = self.url
        url += '?run=addEngine'
        url += '&runid=' + str(self.runID)
        url += '&name=' + name
        url += '&cset=' + str(cset)
        urllib2.urlopen(url)

    def AddTests(self, tests, suite, mode):
        for test in tests:
            self.SubmitTest(test['name'], suite, mode, test['time'])

    def SubmitTest(self, name, suite, mode, time):
        url = self.url
        url += '?name=' + name
        url += '&run=' + str(self.runID)
        url += '&suite=' + suite
        url += '&mode=' + mode
        url += '&time=' + str(time)
        urllib2.urlopen(url)

    def Finish(self, status):
        url = self.url
        url += '?run=finish'
        url += '&status=' + str(status)
        url += '&runid=' + str(self.runID)
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
