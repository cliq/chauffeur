#!/usr/bin/env python3
"""Exercise shared presets, custom teams and project team context through native controls.

Uses an isolated signed Debug copy and temporary repositories/configuration
directories. No provider credentials, user projects or default runtime writes.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

os.umask(0o077)
repository = Path(__file__).resolve().parents[1]
artifacts = repository / '.build/team-agents-artifacts'
artifacts.mkdir(exist_ok=True)
for name in ['summary.json', 'failed-controls.json', 'failed-state.json', 'paused.json']:
    (artifacts / name).unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)
access = subprocess.run([str(helper)], input=json.dumps({'pid': os.getpid(), 'operation': 'inspect'}), capture_output=True, text=True)
if access.returncode:
    print(access.stdout.strip() or access.stderr.strip())
    raise SystemExit(2)



def wait_for(probe, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.12)
    raise AssertionError('Timed out: ' + description)


with tempfile.TemporaryDirectory(prefix='chauffeur-teams-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    fixture_cli = root / 'fake_cli.py'
    for fixture in ('fake_cli.py', 'fake_tui.py'):
        shutil.copy2(repository / 'Prototypes' / fixture, root / fixture)
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur Debug.app', app, symlinks=True)
    identifier = 'dev.chauffeur.editor-probe.' + uuid.uuid4().hex
    socket_path = root / 'runtime/runtime.sock'
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': str(socket_path)}
    plist.write_bytes(plistlib.dumps(info))
    signing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]+) "Developer ID Application: Leonardo Lobato \([^"]+"', signing.stdout, re.M)
    assert len(identities) == 1
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', identities[0], '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    runtime_log = (artifacts / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(app / 'Contents/MacOS/ChauffeurRuntime'), '--data-dir', str(root)], cwd=root, stdout=runtime_log, stderr=runtime_log)
    pid = None
    summary = {}

    def call(method, params=None):
        return json.loads(subprocess.check_output([str(app / 'Contents/MacOS/chauffeurctl'), 'request', method, json.dumps(params or {}), '--socket', str(socket_path)], text=True))

    def snapshot():
        return call('snapshot')

    def records(kind):
        return [r['value'] for r in snapshot()['store'][kind]]

    def ax(operation='inspect', allow_modal=False, **fields):
        if allow_modal:
            fields['actionTimeout'] = 2
        response = json.loads(subprocess.run([str(helper)], input=json.dumps({'pid': pid, 'operation': operation, **fields}), capture_output=True, text=True, check=True).stdout)
        if isinstance(response, dict) and not allow_modal:
            assert response.get('performed'), response
        return response

    def control(title=None, role='AXButton', identifier=None):
        return next((c for c in ax() if (c['identifier'] == identifier if identifier else c['role'] == role and title in [c['title'], c['label']])), None)

    def press(title=None, identifier=None, **fields):
        ax('press', **({'identifier': identifier} if identifier else {'title': title}), **fields)

    def type_text(value, identifier=None, placeholder=None, **fields):
        ax('typeText', value=value, **({'identifier': identifier} if identifier else {'placeholder': placeholder}), **fields)

    def text():
        return '\n'.join(c['value'] + c['label'] + c['title'] for c in ax())

    def dismiss_sheet():
        press('Cancel')
        wait_for(lambda: not control('Cancel'), 'editor dismissed')


    def choose(identifier, option):
        press(identifier=identifier)
        wait_for(lambda: any(c['role'] == 'AXMenuItem' and option in [c['title'], c['label']] for c in ax(includeMenus=True)), 'picker option')
        press(option, role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control(identifier=identifier)['value'] == option, 'picker selection')

    def create_team(name, directory):
        press('Add Team…')
        wait_for(lambda: control(identifier='preset-set.name'), 'team editor')
        type_text(name, identifier='preset-set.name')
        type_text(directory, identifier='team.CODEX_HOME')
        press('Save')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'team saved')
        return next(t for t in records('presetSets') if t['name'] == name)

    try:
        wait_for(socket_path.exists, 'runtime socket')
        subprocess.run(['open', '-n', str(app)], check=True)
        probe = subprocess.run(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], capture_output=True, text=True, check=True)
        pid = json.loads(probe.stdout)['pid']
        wait_for(lambda: 'Custom service running' in text(), 'app connected')
        press('Settings…', role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control('Shared Agent Presets'), 'settings')
        press('Shared Agent Presets')
        press('Add Shared Agent Preset…')
        wait_for(lambda: control(identifier='base-agent.name'), 'base editor')
        type_text('Shared fixture', identifier='base-agent.name')
        type_text('/bin/echo', identifier='base-agent.executable')
        press('Save Shared Agent Preset')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'base saved')
        base = next(b for b in records('baseAgentPresets') if b['name'] == 'Shared fixture')
        assert 'configurationDirectory' not in base
        summary['nativeBaseCreation'] = True
        press('Teams')
        work = create_team('Work fixture', str(root / 'work-config'))
        assert work['agentSelection'] == 'allBase'
        wait_for(lambda: 'Shared fixture' in text(), 'base inherited by Work')
        personal = create_team('Personal fixture', '')
        wait_for(lambda: 'Shared fixture' in text(), 'base inherited by Personal')
        assert personal['agentSelection'] == 'allBase'
        assert not personal['configurationDirectories']['codex']
        summary['newTeamsInheritBaseAgentsAndAllowDefaults'] = True
        press(identifier='preset-set.edit')
        wait_for(lambda: control(identifier='team.agent-selection'), 'team editor')
        choose('team.agent-selection', 'Custom')
        press('Save')
        wait_for(lambda: control('Add from Shared Presets…'), 'custom team')
        copies = [p for p in records('presets') if p['setID'] == personal['id']]
        copy = next(p for p in copies if p['sourceBaseID'] == base['id'])
        assert copy['id'] != base['id']
        press(identifier='preset.edit-' + copy['id'])
        wait_for(lambda: control(identifier='preset.name'), 'custom editor')
        assert not control(identifier='preset.configuration-directory')
        type_text('Personal custom', identifier='preset.name')
        type_text('/bin/cat', identifier='preset.executable')
        press('Save Agent Preset')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'custom saved')
        stored = next(r for r in snapshot()['store']['baseAgentPresets'] if r['value']['id'] == base['id'])
        call('saveBaseAgentPreset', {'record': dict(stored['value'], executable='/bin/false'), 'version': stored['version']})
        custom = next(p for p in records('presets') if p['id'] == copy['id'])
        assert custom['executable'] == '/bin/cat'
        summary['customCopiesEditableAndIndependent'] = True
        press('Add from Shared Presets…')
        wait_for(lambda: control('Shared fixture'), 'base picker')
        press('Shared fixture')
        wait_for(lambda: control(identifier='preset.name'), 'copy editor')
        type_text('Another copy', identifier='preset.name')
        press('Save Agent Preset')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'copy saved')
        assert any(p['name'] == 'Another copy' for p in records('presets'))
        summary['addFromBase'] = True
        press('Open Project Window…', role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control('Create New Project…'), 'welcome')
        press('Create New Project…')
        wait_for(lambda: control(identifier='project.name'), 'project editor')
        type_text('Team fixture project', identifier='project.name')
        press('Start Empty')
        press('Save Project')
        wait_for(lambda: control(identifier='project.team'), 'persistent team control')
        press(identifier='project.team')
        wait_for(lambda: 'CODEX_HOME' in text() and str(root / 'work-config') in text(), 'team paths popover')
        assert control('Change Project Team…')
        summary['projectTeamAndConfigurationVisible'] = True
        press('Change Project Team…')
        wait_for(lambda: control(identifier='project.preset-set'), 'project settings')
        choose('project.preset-set', 'Personal fixture')
        press('Save Project')
        wait_for(lambda: 'Team: Personal fixture' in text(), 'project team changed')
        summary['projectTeamSwitch'] = True
        summary['passed'] = True
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    except Exception:
        if pid:
            try: (artifacts / 'failed-controls.json').write_text(json.dumps(ax(), indent=2))
            except Exception: pass
        (artifacts / 'failed-state.json').write_text(json.dumps(snapshot(), indent=2))
        raise
    finally:
        if pid:
            try: os.kill(pid, 15)
            except ProcessLookupError: pass
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
