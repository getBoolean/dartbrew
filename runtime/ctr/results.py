"""Validate a single runtime journal against the launcher's current-run identity."""
import json

KEYS = ('schema', 'run_id', 'fixture', 'mode', 'compatibility', 'artifact_sha256',
        'build_id', 'environment')
PREFIX = 'CTR_RUNTIME '
# Launcher contract schemas: 1 (cfg only), 2 (cfg host line or netloader argv).
SCHEMAS = (1, 2)


def validate(journal, expected, observation=None):
    result = {'outcome': 'incomplete', 'output': []}
    active = False
    cleanup = None
    terminal = None
    try:
        for line in journal.splitlines():
            if not line.startswith(PREFIX):
                continue
            try:
                record = json.loads(line[len(PREFIX):])
                if not isinstance(record, dict):
                    raise ValueError('record is not an object')
            except ValueError:
                if active:
                    raise ValueError('malformed current-run record')
                continue
            if record.get('run_id') != expected['run_id']:
                if active:
                    raise ValueError('interleaved run')
                continue
            if terminal is not None:
                raise ValueError('record after terminal')
            event = record.get('event')
            if event == 'begin':
                if active or any(record.get(key) != expected[key] for key in KEYS):
                    raise ValueError('duplicate begin or identity mismatch')
                if record['schema'] not in SCHEMAS:
                    raise ValueError('unsupported begin schema')
                active = True
            elif not active:
                raise ValueError('record before begin')
            elif event == 'output' and isinstance(record.get('text'), str):
                result['output'].append(record['text'])
            elif event == 'assert':
                if cleanup is not None or record.get('name') != 'cleanup' or record.get('status') not in ('pass', 'fail'):
                    raise ValueError('invalid cleanup assertion')
                cleanup = record['status']
            elif event == 'terminal':
                terminal = record
            else:
                raise ValueError('unknown event')
        if not active or terminal is None or cleanup is None or terminal.get('assertions') != 1:
            raise ValueError('missing begin, cleanup or terminal')
        outcome = terminal.get('outcome')
        # exit(n) and a nonzero exitCode end the run with exit_code: 0 passes,
        # any other code fails carrying it.
        exit_code = terminal.get('exit_code')
        if 'exit_code' in terminal and (not isinstance(exit_code, int) or isinstance(exit_code, bool)):
            raise ValueError('invalid exit code')
        if (outcome not in ('pass', 'fail', 'incomplete') or (cleanup == 'fail' and outcome != 'fail')
                or (exit_code is not None and (outcome == 'incomplete' or (outcome == 'pass' and exit_code != 0)))):
            raise ValueError('contradictory outcome')
        if observation == 'crash':
            raise ValueError('host observed crash')
        result['outcome'] = outcome
        if exit_code is not None:
            result['exit_code'] = exit_code
    except (KeyError, TypeError, ValueError) as error:
        result['reason'] = str(error)
    return result
