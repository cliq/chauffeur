#!/usr/bin/env python3
"""Exercise the installed Release Sessions helper using isolated data and sessions.

Creates a temporary LaunchAgent; never touches the user's tmux servers or grants.
--access-file reads one byte of an explicitly supplied synthetic fixture and may
show macOS consent. No dialog is answered. --identity additionally checks a
signed helper update, retirement after drain, and surviving sessions after crash.
Artifacts contain process identities and read counts, never protected contents.
"""
import argparse
import ctypes
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


def run(*args, check=True):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()}')
    return result


def wait(fn, timeout=30):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = fn()
        if value:
            return value
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for acceptance checkpoint')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/Chauffeur.app'))
    parser.add_argument('--artifacts', type=Path, default=Path('.local/sessions-acceptance'))
    parser.add_argument('--identity')
    parser.add_argument('--access-file', type=Path)
    parser.add_argument('--quit-ui', action='store_true', help='Also quit the installed desktop app during the check')
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
    since = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    root = Path(tempfile.mkdtemp(prefix='ch-sessions-', dir='/private/tmp'))
    ctl = args.app / 'Contents/MacOS/chauffeurctl'
    tmux = shutil.which('tmux') or '/opt/homebrew/bin/tmux'
    label = 'dev.cliq.chauffeur.sessions-acceptance.' + uuid.uuid4().hex
    domain = f'gui/{os.getuid()}'
    job = f'{domain}/{label}'
    plist = root / 'agent.plist'
    socket = root / 'runtime/runtime.sock'
    evidence = {'root': str(root), 'label': label, 'checks': []}
    responsible = ctypes.CDLL('/usr/lib/libSystem.B.dylib').responsibility_get_pid_responsible_for_pid
    responsible.argtypes = [ctypes.c_int]
    responsible.restype = ctypes.c_int

    def record(name, **values):
        evidence['checks'].append(dict(name=name, **values))
        (args.artifacts / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(name, values, flush=True)

    def call(method, params=None, check=True):
        result = run(ctl, 'request', method, json.dumps(params or {}), '--socket', socket, check=check)
        return json.loads(result.stdout) if result.returncode == 0 else None

    def start(app):
        plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(app / 'Contents/MacOS/ChauffeurRuntime'), '--data-dir', str(root), '--mcp-port', '0'], RunAtLoad=True, KeepAlive=True, ProcessType='Interactive', StandardOutPath=str(root / 'runtime.log'), StandardErrorPath=str(root / 'runtime.log'))))
        run('launchctl', 'bootstrap', domain, plist)
        wait(lambda: call('status', check=False))

    def owners():
        result = []
        for path in (root / 'runtime/session-owners').glob('*/manifest.json'):
            manifest = json.loads(path.read_text())
            ready = path.with_name('ready.json')
            if ready.exists():
                manifest['pid'] = json.loads(ready.read_text())
                manifest['directory'] = str(path.parent)
                result.append(manifest)
        return result

    def pane(session):
        for owner in owners():
            result = run(tmux, '-N', '-S', owner['socketPath'], 'list-panes', '-a', '-F', '#{session_name}|#{pane_pid}|#{pane_id}', check=False)
            for line in result.stdout.splitlines():
                name, pid, identity = line.split('|')
                if name == session['id']:
                    return owner, int(pid), identity
        return None

    def check_pane(session, expected_owner=None):
        owner, pid, identity = wait(lambda: pane(session))
        actual = responsible(pid)
        if expected_owner is not None:
            assert actual == expected_owner, (actual, expected_owner)
        return dict(session=session['id'], pid=pid, pane=identity, responsible=actual, owner=owner['pid'])

    def read_probe(session, suffix):
        owner, _, _ = pane(session)
        output = root / f'python-{suffix}.json'
        script = root / f'python-{suffix}.py'
        source = "import ctypes,json,os\nfrom pathlib import Path\nlib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')\npid=os.getpid()\nresult={'pid':pid,'responsible':lib.responsibility_get_pid_responsible_for_pid(pid)}\n"
        if args.access_file:
            source += f"try:\n with open({str(args.access_file)!r},'rb') as f: result['bytes']=len(f.read(1))\nexcept OSError as e: result['errno']=e.errno\n"
        source += f"Path({str(output)!r}).write_text(json.dumps(result))\n"
        script.write_text(source)
        command = shlex.join(['/opt/homebrew/bin/python3', str(script)])
        run(tmux, '-N', '-S', owner['socketPath'], 'send-keys', '-t', session['id'], command, 'Enter')
        wait(output.exists, timeout=180)
        data = json.loads(output.read_text())
        assert data['responsible'] == owner['pid'], data
        if args.access_file:
            assert data.get('bytes') == 1, data
        record('python-' + suffix, **data)

    try:
        start(args.app)
        uid = lambda: str(uuid.uuid4()).upper()
        now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        team, project, group, folder = uid(), uid(), uid(), uid()
        call('savePresetSet', {'record': dict(id=team, name='Sessions acceptance')})
        call('saveProject', {'record': dict(id=project, name='Sessions acceptance', presetSetID=team, folders=[dict(id=folder, name='Fixture', selectedPath=str(root), canonicalPath=str(root), availability='available', registered=True)], groups=[dict(id=group, name='Default', isDefault=True, archived=False, createdAt=now, updatedAt=now)], archived=False, createdAt=now, updatedAt=now, lastOpenedAt=now)})

        def launch():
            return call('launch', dict(projectID=project, groupID=group, presetID=team, folderID=folder, additionalFolderIDs=[], title='Acceptance shell', allowSharedCheckout=True, coordinationEnabled=False, retryKey=uid(), kind='shell'))

        with ThreadPoolExecutor(max_workers=4) as pool:
            simultaneous = list(pool.map(lambda _: launch(), range(4)))
        first, *peers = simultaneous
        original = check_pane(first)
        assert original['responsible'] == original['owner'], original
        record('initial-owner', **original)
        for peer in peers:
            check_pane(peer, original['owner'])
        assert len(owners()) == 1, 'Concurrent startup created more than one owner'
        record('concurrent-start-shares-one-owner', sessions=len(simultaneous))
        read_probe(first, 'initial')
        if args.quit_ui:
            # The app returns terminateCancel while presenting its asynchronous
            # choice. Select only the non-destructive keep-terminals option.
            run('osascript', '-e', 'tell application id "dev.cliq.chauffeur" to quit', check=False)
            time.sleep(.5)
            run('osascript', '-e', '''
                tell application "System Events" to tell process "Chauffeur"
                    repeat with w in windows
                        if exists button "Quit and Keep All Terminals Running" of w then
                            click button "Quit and Keep All Terminals Running" of w
                            return
                        end if
                        repeat with s in sheets of w
                            if exists button "Quit and Keep All Terminals Running" of s then
                                click button "Quit and Keep All Terminals Running" of s
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            ''')
            wait(lambda: run('pgrep', '-f', '^/Applications/Chauffeur.app/Contents/MacOS/Chauffeur$', check=False).returncode != 0)
            assert check_pane(first, original['owner']) == original
            record('desktop-quit-preserves-owner')
        run('launchctl', 'kickstart', '-k', job)
        wait(lambda: call('status', check=False))
        assert check_pane(first, original['owner']) == original
        second = launch()
        record('runtime-restart-new-session', **check_pane(second, original['owner']))
        read_probe(second, 'after-restart')
        run('launchctl', 'bootout', job)
        assert check_pane(first, original['owner']) == original
        record('runtime-stopped-preserves-owner')
        start(args.app)
        third = launch()
        record('runtime-relaunched-new-session', **check_pane(third, original['owner']))
        read_probe(third, 'after-relaunch')

        if args.identity:
            # A minimal isolated packaged runtime with a distinctly signed helper
            # revision exercises update routing without replacing the real app.
            update = root / 'updated/Chauffeur.app'
            macos = update / 'Contents/MacOS'
            macos.mkdir(parents=True)
            for binary in ['ChauffeurRuntime', 'chauffeurctl']:
                shutil.copy2(args.app / 'Contents/MacOS' / binary, macos / binary)
            helper = update / 'Contents/Library/ChauffeurSessions.app'
            shutil.copytree(args.app / 'Contents/Library/ChauffeurSessions.app', helper)
            info_path = helper / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            info['CFBundleVersion'] = 'acceptance-' + uuid.uuid4().hex
            info_path.write_bytes(plistlib.dumps(info))
            run('codesign', '--force', '--options', 'runtime', '--sign', args.identity, helper)
            run('launchctl', 'bootout', job)
            start(update)
            newer = launch()
            new = check_pane(newer)
            assert new['owner'] != original['owner'] and new['responsible'] == new['owner'], new
            assert check_pane(first, original['owner']) == original
            record('updated-helper-new-owner', **new)
            read_probe(first, 'old-owner-after-update')
            # Remove the update's embedded source; its cached app must keep the
            # existing owner's responsibility and consent intact.
            shutil.rmtree(helper)
            read_probe(newer, 'cached-owner-after-unlink')
            for session in [*simultaneous, second, third]:
                call('stop', dict(sessionID=session['id'], force=True))
            def dead(pid):
                try:
                    os.kill(pid, 0)
                    return False
                except ProcessLookupError:
                    return True
            wait(lambda: dead(original['owner']))
            record('old-owner-exits-after-drain')
            # Recreate the embedded source before the next launch; no fallback
            # is permitted when it is absent.
            shutil.copytree(Path(pane(newer)[0]['appPath']), helper)
            os.kill(new['owner'], signal.SIGTERM)
            wait(lambda: dead(new['owner']))
            survived = check_pane(newer)
            assert survived['pid'] == new['pid'] and survived['pane'] == new['pane']
            replacement = launch()
            fresh = check_pane(replacement)
            assert fresh['owner'] != new['owner'] and fresh['responsible'] == fresh['owner'], fresh
            # Snapshot requests still route into the crashed owner's old server.
            snapshot = call('terminalSnapshot', dict(sessionID=newer['id']))
            assert snapshot['processID'] == new['pid']
            record('owner-crash-preserves-session', **survived)
            record('owner-crash-new-session-new-owner', **fresh)
        record('passed')
    finally:
        if args.access_file:
            from tcc_responsibility import capture_tcc
            try:
                capture_tcc(since, root, args.artifacts / 'tcc-events.json', [item['pid'] for item in evidence['checks'] if 'pid' in item])
            except Exception as error:
                record('tcc-capture-error', error=str(error))
        run('launchctl', 'bootout', job, check=False)
        for owner in owners():
            # Every path and PID came from this unique temporary data root.
            run(tmux, '-N', '-S', owner['socketPath'], 'kill-server', check=False)
            if responsible(owner['pid']) == owner['pid']:
                # Confirm executable path too, so a reused PID is never signaled.
                path = ctypes.create_string_buffer(4096)
                lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
                if lib.proc_pidpath(owner['pid'], path, len(path)) > 0 and path.value.decode().startswith(str(root / 'session-apps') + '/'):
                    try:
                        os.kill(owner['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        if (root / 'runtime.log').exists():
            shutil.copy2(root / 'runtime.log', args.artifacts / 'runtime.log')
        shutil.rmtree(root)
        if args.quit_ui:
            run('open', args.app, check=False)


if __name__ == '__main__':
    main()
