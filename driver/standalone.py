import re
import sys
import ConfigParser
import submitter
import benchmark
import utils
import subprocess


filterOutput = re.compile("Shell-like \w+ results:((?:.*\n)*)End of shell-like result.", re.MULTILINE)
def runGaiaTest(test):
    args = ['./run-benchmark.sh', test]

    nb = 0
    output = ""
    m = None
    while nb < 10:
        try:
            output = utils.Run(args)
            m = filterOutput.search(output)
            if m != None:
                return m.group(1)
        except subprocess.CalledProcessError, e:
            print e.output

        nb = nb + 1
        if nb == 10:
            raise Exception("Fail to execute")


if len(sys.argv) < 2:
    raise Exception('Expect the changeset and config file.')

changeset = sys.argv[1]

benchmarks = {
    'octane': {
        'name' : 'octane',
        'filter' : benchmark.v8_filter
    },
    'ss': {
        'name' : 'sunspider',
        'filter' : benchmark.sunspider_filter
    },
    'kraken': {
        'name' : 'kraken',
        'filter' : benchmark.sunspider_filter
    }
}

config = ConfigParser.RawConfigParser()
config.read(sys.argv[2])

if config.get('main', 'local') == 'yes':
    submit = submitter.FakeSubmitter(config)
else:
    submit = submitter.Submitter(config)

submit.Start()

submit.AddEngine('browser_im_bc', changeset)
for suite in benchmarks.keys():
    try:
        output = runGaiaTest(benchmarks[suite]['name'])
        tests = benchmarks[suite]['filter'](output)
        submit.AddTests(tests, suite, 'browser_im_bc')
    except Exception as e:
        print e

submit.Finish(1)
