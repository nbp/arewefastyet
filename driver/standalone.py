import re
import sys
import ConfigParser
import submitter
import benchmark
import utils
import subprocess

if len(sys.argv) < 3:
    raise Exception('Expect the changeset and config file.')

changeset = sys.argv[1]
configFile = sys.argv[2]
engine = sys.argv[3]
b2gDir = sys.argv[4]


filterOutput = re.compile("Shell-like \w+ results:((?:.*\n)*)End of shell-like result.", re.MULTILINE)
def runGaiaTest(test):
    args = ['./run-benchmark.sh', b2gDir, test]

    nb = 0
    output = ""
    m = None

    # Retry because we might fail to connect to the wifi
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
config.read(configFile)

if config.get('main', 'local') == 'yes':
    submit = submitter.FakeSubmitter(config)
else:
    submit = submitter.Submitter(config)

submit.Start()
submit.AddEngine(engine, changeset)
for suite in benchmarks.keys():
    try:
        output = runGaiaTest(benchmarks[suite]['name'])
        tests = benchmarks[suite]['filter'](output)
        submit.AddTests(tests, suite, engine)
    except Exception as e:
        print e

submit.Finish(1)
