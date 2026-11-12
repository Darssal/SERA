"""Bounded, device-1-only host experiment; never labels reboot as Flutter PASS.

Called by run_platform_qa.py --reboot-check. No raw dumpsys/user content is
written to the result. The APK is a dedicated integration-test entrypoint.
"""
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET

PACKAGE = 'com.sera.sera_flutter'
DEVICE = '127.0.0.1:16416'
# Dart's Directory.systemTemp maps to code_cache in this MuMu/Flutter runtime.
# This host experiment is intentionally restricted to that verified device.
MARKER = 'code_cache/sera-platform-reboot-qa.json'


def active_notification(dump, tag):
    """Accept an active Notification List record, never archive/history text."""
    active = False
    for line in dump.splitlines():
        stripped = line.strip()
        if stripped == 'Notification List:':
            active = True
            continue
        if stripped in ('Enqueued Notification List:', 'Snoozed notifications:',
                        'Ranking Config:', 'Notification Preferences:'):
            active = False
        if (active and stripped.startswith('NotificationRecord(')
                and 'pkg=' + PACKAGE in stripped
                and re.search(r'\btag=' + re.escape(tag) + r'(?:\s|\))', stripped)):
            return True
    return False


def persisted_reminder(xml, scope, reminder_id, fire_at):
    values = {node.get('name'): node.text for node in ET.fromstring(xml)
              if node.tag == 'string'}
    hashed = hashlib.sha256(scope.encode()).hexdigest()
    if values.get('activeScope') != hashed:
        return False
    rows = json.loads(values.get('notifications:' + hashed, '[]'))
    return any(row.get('id') == reminder_id and row.get('fireAt') == fire_at
               and bool(row.get('version')) for row in rows)


def run_reboot_experiment(args, project):
    if args.device != DEVICE:
        raise RuntimeError('This experiment is restricted to MuMu device 1 (' + DEVICE + ').')
    prefix = [args.adb, '-s', DEVICE]
    result = {
        'schemaVersion': 1,
        'experiment': 'mumu1-scheduled-notification-reboot',
        'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'device': DEVICE,
        'status': 'not_completed',
        'normalScheduledNotificationObserved': False,
        'rebootScheduledNotificationObserved': False,
        'persistedToDiskVerifiedBeforeReboot': False,
        'kernelBootIdChanged': False,
        'appActivityLaunchedAfterReboot': False,
        'manualBootBroadcastSent': False,
        'flutterResultClassification': 'not_a_flutter_test_pass',
        'cleanup': {'testAppDataCleared': False, 'temporaryForwardRemoved': False},
    }
    output = project / 'docs/qa/mumu1-reminder-reboot.json'
    log_path = project / '.local/platform-reboot-check.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    state = None
    process = None
    ready_at = None

    def adb(*command, timeout=4):
        return subprocess.run(prefix + list(command), text=True, capture_output=True,
                              timeout=timeout, encoding='utf-8', errors='replace')

    def boot_id():
        return adb('shell', 'cat', '/proc/sys/kernel/random/boot_id').stdout.strip()

    def observe(tag):
        # Filter at the OS level and retain only a boolean, never raw content.
        dump = adb('shell', 'dumpsys', 'notification', '--noredact', '--package', PACKAGE)
        return dump.returncode == 0 and active_notification(dump.stdout, tag)

    def read_status():
        try:
            with urllib.request.urlopen('http://127.0.0.1:18799/status', timeout=0.4) as reply:
                return json.load(reply)
        except (OSError, ValueError):
            return {}

    try:
        if adb('get-state').stdout.strip() != 'device':
            raise RuntimeError('MuMu device 1 is not connected; no other instance will be used.')
        initial_boot = boot_id()
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', initial_boot):
            raise RuntimeError('Cannot obtain a trustworthy pre-reboot kernel boot ID.')
        if adb('forward', 'tcp:18799', 'tcp:8799').returncode:
            raise RuntimeError('Cannot forward the test-only QA coordination port.')
        previous_run_id = read_status().get('runId')
        # flutter test may uninstall its APK on disconnect, invalidating boot
        # recovery. A dedicated flagged app entrypoint leaves the APK installed.
        command = [args.flutter, 'run', '--debug', '-t', 'integration_test/platform_device_test.dart',
                   '-d', DEVICE, '--no-pub', '--no-hot',
                   '--dart-define=PLATFORM_QA_REBOOT=true']
        if os.name == 'nt':
            command = ['cmd.exe', '/d', '/c'] + command
        with log_path.open('w', encoding='utf-8') as log:
            process = subprocess.Popen(command, cwd=project, stdout=log, stderr=subprocess.STDOUT)
            setup_deadline = time.monotonic() + 90
            granted_pids = set()
            while time.monotonic() < setup_deadline:
                if process.poll() is not None:
                    raise RuntimeError('QA APK did not become ready; inspect the local Flutter log.')
                pid = adb('shell', 'pidof', PACKAGE).stdout.strip()
                if pid and pid not in granted_pids:
                    api = adb('shell', 'getprop', 'ro.build.version.sdk').stdout.strip()
                    if api.isdecimal() and int(api) >= 33:
                        grant = adb('shell', 'pm', 'grant', PACKAGE,
                                    'android.permission.POST_NOTIFICATIONS')
                        if grant.returncode:
                            raise RuntimeError('Cannot grant this test APK its declared notification permission.')
                    granted_pids.add(pid)
                candidate = read_status()
                if (candidate.get('stage') == 'reboot-ready'
                        and candidate.get('mode') == 'platform-reboot-qa'
                        and candidate.get('runId') != previous_run_id):
                    state = candidate
                    break
                time.sleep(0.25)
            if state is None:
                raise RuntimeError('QA setup exceeded 90 seconds; no reboot performed.')
            run_id = str(state.get('runId', ''))
            if not run_id.isdecimal() or state.get('scope') != 'qa-platform-reboot:' + run_id:
                raise RuntimeError('Refusing unrecognized QA scope.')
            marker = adb('shell', 'run-as', PACKAGE, 'cat', MARKER)
            marker_value = json.loads(marker.stdout)
            if marker_value.get('runId') != run_id or marker_value.get('mode') != 'platform-reboot-qa':
                raise RuntimeError('QA APK persistent marker does not match this experiment.')
            result['qaRunId'] = run_id
            result['exactScheduling'] = state.get('exact') is True
            ready_at = time.monotonic()
            experiment_deadline = ready_at + 120
            hashed = hashlib.sha256(state['scope'].encode()).hexdigest()
            normal_tag = hashed + ':' + state['normalReminderId']
            reboot_tag = hashed + ':' + state['rebootReminderId']
            normal_deadline = min(experiment_deadline, ready_at + 18)
            while time.monotonic() < normal_deadline:
                if observe(normal_tag):
                    result['normalScheduledNotificationObserved'] = True
                    result['normalObservedElapsedSeconds'] = round(time.monotonic() - ready_at, 2)
                    break
                time.sleep(0.35)
            if not result['normalScheduledNotificationObserved']:
                raise RuntimeError('The actual 5-second scheduled notification was not observable; no reboot performed.')
            disk = adb('shell', 'run-as', PACKAGE, 'cat', 'shared_prefs/sera_platform.xml')
            if not persisted_reminder(disk.stdout, state['scope'], state['rebootReminderId'], state['rebootFireAt']):
                raise RuntimeError('The reboot reminder was not verified on disk; no reboot performed.')
            result['persistedToDiskVerifiedBeforeReboot'] = True
            result['rebootFireAtEpochMs'] = state['rebootFireAt']
            print('QA host: real normal alarm observed; persisted reboot reminder verified. Rebooting only MuMu device 1.', flush=True)
            if adb('reboot').returncode:
                raise RuntimeError('The device-1 reboot command failed.')
            result['rebootRequested'] = True
            while time.monotonic() < experiment_deadline:
                try:
                    subprocess.run([args.adb, 'connect', DEVICE], capture_output=True, timeout=3)
                    current_boot = boot_id()
                    completed = adb('shell', 'getprop', 'sys.boot_completed').stdout.strip()
                    if current_boot and current_boot != initial_boot and completed == '1':
                        result['kernelBootIdChanged'] = True
                        result['bootCompletedElapsedSeconds'] = round(time.monotonic() - ready_at, 2)
                        break
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(1)
            if not result['kernelBootIdChanged']:
                raise RuntimeError('Device-1 reboot did not complete inside the bounded experiment.')
            # Do not launch the activity or send synthetic BOOT_COMPLETED. Only
            # the genuine boot receiver can restore this alarm after kernel boot.
            while time.monotonic() < experiment_deadline:
                if observe(reboot_tag):
                    result['rebootScheduledNotificationObserved'] = True
                    result['rebootObservedElapsedSeconds'] = round(time.monotonic() - ready_at, 2)
                    break
                time.sleep(0.5)
            if not result['rebootScheduledNotificationObserved']:
                raise RuntimeError('No active unique reboot reminder was observed within 120 seconds; do not claim boot recovery passed.')
            result['status'] = 'passed_host_experiment'
            result['bootRecoveryEvidence'] = 'Kernel reboot changed boot ID, no activity relaunch/manual broadcast, and unique persisted alarm notification appeared after boot.'
    except Exception as error:
        result['status'] = 'failed_or_environment_limited'
        # Error strings are fixed QA messages; never include dumpsys or app data.
        result['errorType'] = type(error).__name__
        result['error'] = str(error) if isinstance(error, RuntimeError) else 'Host QA operation failed; inspect local tooling without publishing raw data.'
    finally:
        if ready_at is not None:
            result['experimentElapsedSeconds'] = round(time.monotonic() - ready_at, 2)
        if process is not None:
            if process.poll() is None:
                if os.name == 'nt':
                    # Only this runner's process tree, never unrelated Flutter.
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                   capture_output=True, timeout=5)
                else:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
            result['flutterExitCodeAfterRebootDisconnect'] = process.poll()
        # Only erase an APK bearing our persisted QA marker. Never clear an
        # unrelated/formal app merely because its package name is the same.
        try:
            marker = adb('shell', 'run-as', PACKAGE, 'cat', MARKER)
            value = json.loads(marker.stdout)
            if (state is not None and value.get('mode') == 'platform-reboot-qa'
                    and value.get('runId') == state.get('runId')):
                cleared = adb('shell', 'pm', 'clear', PACKAGE)
                result['cleanup']['testAppDataCleared'] = cleared.returncode == 0 and 'Success' in cleared.stdout
        except (ValueError, OSError, subprocess.TimeoutExpired):
            pass
        try:
            removed = adb('forward', '--remove', 'tcp:18799')
            result['cleanup']['temporaryForwardRemoved'] = removed.returncode == 0
            forwards = subprocess.run([args.adb, 'forward', '--list'], text=True,
                                      capture_output=True, timeout=4)
            result['cleanup']['temporaryForwardAbsent'] = (
                forwards.returncode == 0 and not any(
                    line.split()[:2] == [DEVICE, 'tcp:18799']
                    for line in forwards.stdout.splitlines()))
        except (OSError, subprocess.TimeoutExpired):
            pass
        if state is not None and not result['cleanup']['testAppDataCleared']:
            result['cleanup']['requiresManualQaCleanup'] = True
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('QA host experiment: ' + result['status'] + '; sanitized evidence: ' + str(output), flush=True)
    return 0 if result['status'] == 'passed_host_experiment' else 1
