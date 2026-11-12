"""Run native Flutter QA serially; grant only SERA and mutate only QA events.

The optional test-only loopback server is compiled solely into integration_test.
External edits use Android's actual Calendar Provider shell tool, outside SERA.
"""
import argparse
import json
import os
import pathlib
import subprocess
import time
import urllib.request

DEVICE = '127.0.0.1:16416'
QA_PACKAGE = 'com.sera.sera_flutter.qa'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flutter', required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--device', default=DEVICE)
    parser.add_argument('--external', action='store_true')
    parser.add_argument('--reboot-check', action='store_true',
                        help='Disabled until the legacy reboot helper is migrated to the isolated QA package.')
    args = parser.parse_args()
    if args.device != DEVICE:
        parser.error('Platform QA is restricted to MuMu device 1 (' + DEVICE + ').')
    project = pathlib.Path(__file__).resolve().parents[2]
    if args.reboot_check:
        parser.error('The legacy reboot helper targets production app data and is disabled here.')
    prefix = [args.adb, '-s', args.device]

    def adb(*command):
        return subprocess.run(prefix + list(command), text=True, capture_output=True, timeout=8)

    if args.external:
        forwarded = adb('forward', 'tcp:18799', 'tcp:8799')
        if forwarded.returncode:
            raise RuntimeError(forwarded.stderr)
    command = [args.flutter, 'test', 'integration_test/platform_device_test.dart',
               '-d', args.device, '--no-uninstall', '--reporter', 'expanded']
    if args.external:
        command.append('--dart-define=PLATFORM_QA_EXTERNAL=true')
    if os.name == 'nt':
        command = ['cmd.exe', '/d', '/c'] + command
    environment = os.environ.copy()
    environment['SERA_ANDROID_QA'] = '1'
    process = subprocess.Popen(command, cwd=project, env=environment)
    seen = set()
    granted = set()
    try:
        while process.poll() is None:
            current = adb('shell', 'pidof', QA_PACKAGE).stdout.strip()
            if current and current not in granted:
                for name in ('READ_CALENDAR', 'WRITE_CALENDAR', 'RECORD_AUDIO'):
                    result = adb('shell', 'pm', 'grant', QA_PACKAGE, 'android.permission.' + name)
                    if result.returncode:
                        raise RuntimeError(result.stderr)
                sdk = adb('shell', 'getprop', 'ro.build.version.sdk').stdout.strip()
                if int(sdk) >= 33:
                    result = adb('shell', 'pm', 'grant', QA_PACKAGE, 'android.permission.POST_NOTIFICATIONS')
                    if result.returncode:
                        raise RuntimeError(result.stderr)
                granted.add(current)
                print('QA: declared SERA runtime permissions granted on ' + args.device, flush=True)
            if args.external:
                try:
                    with urllib.request.urlopen('http://127.0.0.1:18799/status', timeout=0.3) as response:
                        state = json.load(response)
                except (OSError, ValueError):
                    state = {}
                stage = state.get('stage')
                if stage in ('external-update', 'external-delete') and stage not in seen:
                    event_id = str(state['eventId'])
                    if not event_id.isdecimal():
                        raise RuntimeError('QA event ID must be numeric')
                    checked = adb('shell', 'content', 'query', '--uri', 'content://com.android.calendar/events', '--where', '_id=' + event_id,
                                  '--projection', 'title:customAppUri').stdout
                    if 'qa-external-conflict' not in checked:
                        raise RuntimeError('Refusing to edit a non-QA calendar event')
                    edited = adb('shell', 'content', 'update', '--uri', 'content://com.android.calendar/events', '--where', '_id=' + event_id,
                                 '--bind', 'title:s:SERA_QA_' + stage.replace('-', '_'))
                    verified = adb('shell', 'content', 'query', '--uri', 'content://com.android.calendar/events', '--where', '_id=' + event_id,
                                   '--projection', 'title').stdout
                    if edited.returncode or ('SERA_QA_' + stage.replace('-', '_')) not in verified:
                        raise RuntimeError(edited.stdout + edited.stderr)
                    request = urllib.request.Request('http://127.0.0.1:18799/advance',
                        data=json.dumps({'stage': stage}).encode(), headers={'Content-Type': 'application/json'}, method='POST')
                    with urllib.request.urlopen(request, timeout=2) as response:
                        response.read()
                    seen.add(stage)
                    print('QA: actual external Calendar Provider edit for ' + stage, flush=True)
            time.sleep(0.2)
    except BaseException:
        process.terminate()
        process.wait(timeout=15)
        raise
    finally:
        if args.external:
            adb('forward', '--remove', 'tcp:18799')
    result = process.wait()
    if args.external and result == 0 and seen != {'external-update', 'external-delete'}:
        raise RuntimeError('External conflict stages did not both run')
    raise SystemExit(result)


if __name__ == '__main__':
    main()
