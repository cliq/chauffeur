#!/usr/bin/env python3
"""Exercise Chauffeur worker lifecycle through IPC + HTTP MCP with fixture CLIs.

No provider calls or real profiles. Proves same-worktree launch, overrides,
YOLO, durable messages, retained close, retries, replacement and restart.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('CHAUFFEUR_RUNTIME_BINARY', REPO / '.build/debug/ChauffeurRuntime')).resolve()

def uid():
    return str(uuid.uuid4()).upper()

def wait(probe, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except (OSError, ValueError, AssertionError):
            pass
        time.sleep(.1)
    raise AssertionError('Timed out waiting for fixture')

def main():
    with tempfile.TemporaryDirectory(prefix='chauffeur-orchestration-', dir='/tmp') as directory:
        root = Path(directory)
        checkout, profile = root / 'repo', root / 'profile'
        checkout.mkdir(); profile.mkdir()
        subprocess.run(['git', 'init', '-q', str(checkout)], check=True)
        subprocess.run(['git', '-C', str(checkout), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Fixture'], check=True)
        log = (root / 'runtime.log').open('w')
        runtime = None
        def start():
            return subprocess.Popen([str(BINARY), '--data-dir', str(root)], stdout=log, stderr=log, env=dict(os.environ, HOME=str(root), SHELL='/bin/false'))
        def call(method, params=None):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(35)
                connection.connect(str(root / 'runtime/runtime.sock'))
                data = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
                connection.sendall(struct.pack('!I', len(data)) + data)
                def exact(count):
                    data = b''
                    while len(data) < count:
                        part = connection.recv(count-len(data))
                        assert part
                        data += part
                    return data
                response = json.loads(exact(struct.unpack('!I', exact(4))[0]))
                assert not response.get('error'), response.get('error')
                return response.get('result')
        def tool(token, name, args=None):
            port = json.loads((root / 'runtime/mcp-port.json').read_text())
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=360)
            connection.request('POST', '/mcp', json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}), {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Authorization': 'Bearer '+token})
            response = connection.getresponse(); result = json.loads(response.read())['result']; connection.close()
            assert not result.get('isError'), result
            return json.loads(result['content'][0]['text'])
        def fixture(session):
            path = Path(session['launch']['workingDirectory']) / ('.chauffeur-fixture-'+session['id']+'.json')
            return wait(lambda: json.loads(path.read_text()))
        try:
            runtime = start(); wait(lambda: call('status').get('mcpEndpoint'))
            team, preset, project, folder, group = [uid() for _ in range(5)]
            now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            call('savePresetSet', {'record': {'id': team, 'name': 'Fixture', 'agentSelection': 'custom', 'configurationDirectories': {'codex': str(profile)}, 'revision': 1, 'archived': False}})
            call('savePreset', {'record': {'id': preset, 'setID': team, 'name': 'Fixture', 'kind': 'codex', 'executable': str(REPO / 'Prototypes/fake_cli.py'), 'configurationDirectory': str(profile), 'arguments': ['--model', 'preset-model'], 'integration': 'unverified', 'archived': False}})
            call('saveProject', {'record': {'id': project, 'name': 'Orchestration fixture', 'presetSetID': team, 'folders': [{'id': folder, 'name': 'Repo', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}], 'groups': [{'id': group, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
            worktree = call('createWorktree', {'projectID': project, 'folderID': folder, 'branch': 'fixture/worker', 'baseRef': 'HEAD'})['value']
            parent = call('launch', {'projectID': project, 'groupID': group, 'presetID': preset, 'folderID': folder, 'worktreeID': worktree['id'], 'title': 'Coordinator', 'additionalFolderIDs': [], 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
            parent_data = fixture(parent); token = parent_data['token']
            assert '--dangerously-bypass-approvals-and-sandbox' not in parent_data['arguments']
            discovery = tool(token, 'chauffeur_discover')
            assert discovery['worktreeID'] == worktree['id']
            args = {'task': 'First task', 'presetID': preset, 'folderID': folder, 'worktreeID': worktree['id'], 'shareCheckout': True, 'model': 'custom-model', 'reasoningEffort': 'high', 'retryKey': 'first'}
            first = tool(token, 'chauffeur_delegate', args)
            assert first['state'] == 'running', first
            assert tool(token, 'chauffeur_delegate', args)['childID'] == first['childID']
            child = next(s for s in call('snapshot')['sessions'] if s['id'] == first['childID'])
            data = fixture(child)
            assert child['launch']['workingDirectory'] == worktree['path']
            assert child['historyProtected'] and child['launch']['selectedModel'] == 'custom-model'
            assert '--dangerously-bypass-approvals-and-sandbox' in data['arguments'] and 'preset-model' not in data['arguments']
            child_token = data['token']
            message = tool(token, 'chauffeur_send_message', {'recipientID': child['id'], 'body': 'context', 'retryKey': 'context'})
            assert tool(child_token, 'chauffeur_inbox')[0]['id'] == message['id']
            # Exercise the real HTTP transport while the coordinator is suspended.
            # Set CHAUFFEUR_INBOX_PROBE_DELAY=65 to cross the usual MCP timeout.
            delay = float(os.environ.get('CHAUFFEUR_INBOX_PROBE_DELAY', '1'))
            with ThreadPoolExecutor(max_workers=1) as executor:
                waiting = executor.submit(tool, token, 'chauffeur_inbox', {'waitSeconds': 300})
                time.sleep(delay)
                assert not waiting.done(), 'Inbox wait returned before a message arrived'
                started = time.monotonic()
                report = tool(child_token, 'chauffeur_report_result', {'delegationID': first['id'], 'turnID': first['currentTurnID'], 'result': 'Needs correction', 'retryKey': 'report'})
                assert waiting.result(timeout=5)[0]['id'] == report['id']
                assert time.monotonic() - started < 5
            assert tool(token, 'chauffeur_inbox', {'acknowledge': [report['id']]}) == []
            print(f'PASS: HTTP inbox remained suspended for {delay:g}s and woke on result', flush=True)
            status = tool(token, 'chauffeur_delegation_status', {'delegationID': first['id']})
            assert status['result'] == 'Needs correction'
            follow = tool(token, 'chauffeur_follow_up', {'delegationID': first['id'], 'expectedTurnID': first['currentTurnID'], 'prompt': 'Correction', 'retryKey': 'follow'})
            assert follow['state'] == 'failed'  # Fixture version has no verified native composer.
            close_args = {'delegationID': first['id'], 'outcome': 'replaced', 'reason': 'Fresh correction context', 'retryKey': 'close'}
            closed = tool(token, 'chauffeur_close_session', close_args)
            assert closed['state'] == 'completed', closed
            assert tool(token, 'chauffeur_close_session', close_args)['id'] == closed['id']
            ended = next(s for s in call('snapshot')['sessions'] if s['id'] == child['id'])
            assert ended['closureOutcome'] == 'replaced' and ended['historyProtected']
            assert (root / 'runtime/snapshots' / child['id'] / 'latest.json').exists()
            next_args = dict(args, task='Correct first task', retryKey='replacement', predecessorID=first['id'], model='replacement-model')
            replacement = tool(token, 'chauffeur_delegate', next_args)
            assert replacement['childID'] != first['childID'] and replacement['state'] == 'running', replacement
            next_session = next(s for s in call('snapshot')['sessions'] if s['id'] == replacement['childID'])
            replacement_data = fixture(next_session)
            # Recovery changes control ownership without rewriting original parent attribution.
            call('closeSession', {'sessionID': parent['id']})
            successor = call('launch', {'projectID': project, 'groupID': group, 'presetID': preset, 'folderID': folder, 'worktreeID': worktree['id'], 'title': 'Recovered coordinator', 'additionalFolderIDs': [], 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
            token = fixture(successor)['token']
            recovered = tool(token, 'chauffeur_recover_workers', {'previousCoordinatorID': parent['id'], 'retryKey': 'recover'})
            assert any(d['id'] == replacement['id'] and d['parentID'] == parent['id'] and d['controllerID'] == successor['id'] for d in recovered)
            report = tool(replacement_data['token'], 'chauffeur_report_result', {'delegationID': replacement['id'], 'turnID': replacement['currentTurnID'], 'result': 'After recovery', 'retryKey': 'recovered-report'})
            assert report['recipientID'] == successor['id']
            accepted_args = {'delegationID': replacement['id'], 'outcome': 'accepted', 'reason': 'Verified fixture', 'retryKey': 'accept'}
            accepted = tool(token, 'chauffeur_close_session', accepted_args)
            assert accepted['state'] == 'completed'
            # A forced stop can remove the pane before a final capture exists.
            missing = tool(token, 'chauffeur_delegate', dict(args, task='History failure fixture', retryKey='missing-history'))
            missing_session = next(s for s in call('snapshot')['sessions'] if s['id'] == missing['childID'])
            fixture(missing_session)
            call('stop', {'sessionID': missing['childID'], 'force': True})
            (root / 'runtime/snapshots' / missing['childID'] / 'latest.json').unlink(missing_ok=True)
            normal = {'delegationID': missing['id'], 'outcome': 'abandoned', 'reason': 'Missing final capture fixture', 'retryKey': 'normal-missing'}
            assert tool(token, 'chauffeur_close_session', normal)['state'] == 'failed'
            forced = tool(token, 'chauffeur_close_session', dict(normal, force=True, retryKey='force-missing'))
            assert forced['state'] == 'completed' and forced.get('historyWarning'), forced
            runtime.terminate(); runtime.wait(timeout=10); runtime = start()
            wait(lambda: call('status').get('mcpEndpoint'))
            assert tool(token, 'chauffeur_close_session', accepted_args)['id'] == accepted['id']
            assert {child['id'], replacement['childID']} <= {s['id'] for s in call('snapshot')['sessions']}
            print('PASS: worktree, overrides, YOLO, messages, reports, safe follow-up rejection, close, replacement, recovery, force-close warning, retry, restart and retained history')
        finally:
            if runtime and runtime.poll() is None:
                try: call('forceStopAllSessions')
                except Exception: pass
                runtime.terminate(); runtime.wait(timeout=10)
            log.close()

if __name__ == '__main__':
    main()
