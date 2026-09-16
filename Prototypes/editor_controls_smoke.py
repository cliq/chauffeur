#!/usr/bin/env python3
"""Exercise preset, project and group editors through actual macOS controls.

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
artifacts = repository / '.build/editor-controls-artifacts'
artifacts.mkdir(exist_ok=True)
for name in ['summary.json', 'failed-controls.json', 'failed-state.json', 'paused.json']:
    (artifacts / name).unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)


def wait_for(probe, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.12)
    raise AssertionError('Timed out: ' + description)


with tempfile.TemporaryDirectory(prefix='chauffeur-editors-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur.app', app, symlinks=True)
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
    runtime = subprocess.Popen([str(app / 'Contents/MacOS/ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
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

    def choose_path(path, title=None, identifier=None):
        # Running a modal panel inside AXPress can leave its keyboard input
        # unresponsive. Open it from the same native mouse event a user sends.
        time.sleep(0.3)  # Finish any preceding sheet/menu transition before hit testing.
        button = control(title=title, identifier=identifier)
        ax('click', **({'identifier': identifier} if identifier else {'title': title}),
           x=button['frame']['width'] / 2, y=button['frame']['height'] / 2)
        wait_for(lambda: control('Open'), 'native open panel')
        fields = [c for c in ax() if c['role'] == 'AXTextField' and c['identifier'] and c['identifier'] not in ['preset.name', 'preset.executable', 'preset.configuration-directory', 'project.name']]
        assert fields, 'No native file-panel field available for keyboard focus'
        field = fields[0]
        ax('click', identifier=field['identifier'], x=field['frame']['width'] / 2, y=field['frame']['height'] / 2)
        ax('key', identifier=fields[0]['identifier'], keyCode=5, modifiers=['command', 'shift'], systemKeyboard=True)
        wait_for(lambda: control(identifier='PathTextField'), 'Go to Folder')
        type_text(str(path), identifier='PathTextField', systemKeyboard=True)
        ax('key', identifier='PathTextField', keyCode=36, systemKeyboard=True)
        wait_for(lambda: not control(identifier='GoToWindow'), 'native folder navigation')
        press('Open', allow_modal=True)
        wait_for(lambda: not control('Open'), 'native panel completed')

    def choose_popup(title, option):
        identifiers = {'Default preset': 'preset-set.default-preset', 'Preset set': 'project.preset-set'}
        if control(identifier=identifiers[title])['value'] == option:
            return
        press(identifier=identifiers[title])
        wait_for(lambda: any(c['role'] == 'AXMenuItem' and option in [c['title'], c['label']] for c in ax(includeMenus=True)), 'picker option ' + option)
        press(option, role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control(identifier=identifiers[title])['value'] == option, 'picker selection ' + option)
        wait_for(lambda: not any(c['role'] == 'AXMenuItem' and option in [c['title'], c['label']] for c in ax()), 'picker menu closed')
        time.sleep(0.3)

    def settings():
        press('Settings…', role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control('Presets'), 'Settings window')
        press('Presets')

    def welcome():
        press('Open Project Window…', role='AXMenuItem', includeMenus=True)
        wait_for(lambda: control('Create New Project…'), 'Welcome window')

    def project_actions(option):
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'previous editor closed')
        press(identifier='ellipsis.circle')
        wait_for(lambda: any(c['role'] == 'AXMenuItem' and option in [c['title'], c['label']] for c in ax(includeMenus=True)), 'project action')
        press(option, role='AXMenuItem', includeMenus=True)

    def project_menu(project_id, option):
        project_name = next(p['name'] for p in records('projects') if p['id'] == project_id)
        time.sleep(0.3)
        # The most recent fixture project is first, but List can retain a
        # previous offset after reordering. AX also exposes clipped row text.
        scroll = next(c for c in ax(windowIdentifier='welcome') if c['role'] == 'AXScrollArea')
        ax('scroll', role='AXScrollArea', windowIdentifier='welcome',
           x=scroll['frame']['width'] / 2, y=scroll['frame']['height'] / 2, lines=100)
        time.sleep(0.3)
        row = next(c for c in ax() if c['identifier'] == 'project-' + project_id and c['value'] == project_name)
        assert row['frame']['y'] >= scroll['frame']['y'] and row['frame']['y'] + row['frame']['height'] <= scroll['frame']['y'] + scroll['frame']['height'], 'Context-menu target must be visible'
        ax('rightClick', identifier='project-' + project_id, matchValue=project_name, windowIdentifier='welcome',
           x=row['frame']['width'] / 2, y=row['frame']['height'] / 2)
        wait_for(lambda: any(c['role'] == 'AXMenuItem' and option in [c['title'], c['label']] for c in ax(includeMenus=True)), 'project context menu')
        press(option, role='AXMenuItem', includeMenus=True)

    def git(path, *arguments):
        subprocess.run(['git', '-C', str(path), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *arguments], capture_output=True, check=True)

    def create_set(name):
        press('Add Set…')
        wait_for(lambda: control(identifier='preset-set.name'), 'set editor')
        assert not control('Save')['enabled']
        type_text(name, identifier='preset-set.name')
        press('Save')
        saved = wait_for(lambda: next((s for s in records('presetSets') if s['name'] == name), None), 'preset set saved')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'set editor closed')
        return saved

    try:
        wait_for(socket_path.exists, 'runtime socket')
        subprocess.run(['open', '-n', str(app)], check=True)
        probe = subprocess.run(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], capture_output=True, text=True, check=True)
        pid = json.loads(probe.stdout)['pid']
        wait_for(lambda: 'Background service running' in text(), 'app connected')
        assert not control('Create New Project…')['enabled']
        settings()
        personal = create_set('Personal fixture')
        client = create_set('Client fixture')
        summary['nativePresetSetCreation'] = True
        print('Preset sets created', flush=True)

        press('Add Preset…')
        wait_for(lambda: control(identifier='preset.name'), 'preset editor')
        assert not control('Save Preset')['enabled']
        type_text('Native fixture', identifier='preset.name')
        type_text(str(root / 'missing-profile'), identifier='preset.configuration-directory')
        press('Save Preset')
        wait_for(lambda: 'Directory is missing' in text(), 'invalid directory error')
        assert records('presets') == []
        profile = root / '.profile-fixture'; profile.mkdir()
        choose_path(profile, identifier='preset.choose-configuration-directory')
        assert control(identifier='preset.configuration-directory')['value'] == str(profile)
        choose_path(repository / 'Prototypes/fake_cli.py', identifier='preset.choose-executable')
        assert control(identifier='preset.executable')['value'] == str(repository / 'Prototypes/fake_cli.py')
        ax('typeText', title='Launch arguments', role='AXTextArea', value='--model "unfinished')
        press('Save Preset')
        wait_for(lambda: 'quote' in text().lower(), 'argument validation')
        assert records('presets') == []
        ax('typeText', title='Launch arguments', role='AXTextArea', value='--model "fixture model" --yolo')
        press('Save Preset')
        preset = wait_for(lambda: next(iter(records('presets')), None), 'preset saved')
        wait_for(lambda: not any(c['role'] == 'AXSheet' for c in ax()), 'preset editor closed')
        assert preset['setID'] == client['id'], 'Preset must belong to the selected set'
        assert preset['configurationDirectory'] == str(profile)
        assert preset['arguments'] == ['--model', 'fixture model', '--yolo']
        summary['nativeProfileAndExecutablePickers'] = True
        summary['invalidDirectoryAndArgumentsStayUnsaved'] = True
        summary['literalHyphensAndQuotedArguments'] = True
        print('Preset validation and native file panels passed', flush=True)

        press(identifier='preset-set.edit')
        wait_for(lambda: control(identifier='preset-set.name'), 'set edit')
        choose_popup('Default preset', 'Native fixture')
        press('Save')
        wait_for(lambda: next(s for s in records('presetSets') if s['id'] == client['id']).get('defaultPresetID') == preset['id'], 'default preset saved')
        ax('closeWindow', identifier='com_apple_SwiftUI_Settings_window')
        welcome()
        press('Create New Project…')
        wait_for(lambda: control(identifier='project.name'), 'project editor')
        type_text('Native Project A', identifier='project.name')
        choose_popup('Preset set', 'Client fixture')
        press('Start Empty')
        press('Save Project')
        project = wait_for(lambda: next((p for p in records('projects') if p['name'] == 'Native Project A'), None), 'empty project saved')
        assert project['folders'] == [] and project['presetSetID'] == client['id']
        wait_for(lambda: control(identifier='ellipsis.circle'), 'project window')
        time.sleep(1)  # Allow the sheet and Welcome close animations to finish.
        visible = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        (artifacts / 'created-project-windows.json').write_text(json.dumps(visible, indent=2))
        assert len(visible['visibleWindows']) == 1, 'Creating a project must dismiss Welcome after its sheet closes'
        summary['creatingProjectDismissesWelcome'] = True
        assert len(project['groups']) == 1 and project['groups'][0]['isDefault']
        summary['nativeEmptyProjectCreation'] = True
        print('Empty project created with its default group', flush=True)

        project_actions('Manage Groups…')
        wait_for(lambda: control('Add Group'), 'group editor')
        type_text('Review', placeholder='New group name')
        press('Add Group')
        press('Save Groups')
        project = wait_for(lambda: next((p for p in records('projects') if p['id'] == project['id'] and len(p['groups']) == 2), None), 'group saved')
        group = next(g for g in project['groups'] if not g['isDefault'])
        project_actions('Manage Groups…')
        wait_for(lambda: control(identifier='group.name-' + group['id']), 'group edit')
        type_text('Review renamed', identifier='group.name-' + group['id'])
        press('Archive')
        press('Save Groups')
        wait_for(lambda: any(g['id'] == group['id'] and g['name'] == 'Review renamed' and g['archived'] for p in records('projects') for g in p['groups']), 'group archive')
        project_actions('Manage Groups…')
        wait_for(lambda: control('Reopen'), 'archived group')
        press('Reopen')
        press('Save Groups')
        wait_for(lambda: any(g['id'] == group['id'] and not g['archived'] for p in records('projects') for g in p['groups']), 'group reopen')
        summary['nativeGroupCreateRenameArchiveReopen'] = True
        saved = next(p for p in records('projects') if p['id'] == project['id'])
        project_actions('Manage Groups…')
        wait_for(lambda: control('Add Group'), 'group editor for cancellation')
        type_text('Discard this group', placeholder='New group name')
        press('Add Group')
        dismiss_sheet()
        assert next(p for p in records('projects') if p['id'] == project['id']) == saved
        summary['groupCancellationPreservesRecord'] = True
        ax('closeWindow', title='Native Project A', role='AXWindow')
        print('Group create/rename/archive/reopen/cancel passed', flush=True)

        parent = root / 'repositories'; parent.mkdir()
        for name in ['alpha', 'beta']:
            folder = parent / name; folder.mkdir()
            git(folder, 'init', '-q', '-b', 'main')
            git(folder, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'Fixture')
        git(parent / 'alpha', 'worktree', 'add', '-q', '-b', 'linked', str(parent / 'linked'))
        (parent / 'loop').symlink_to(parent, target_is_directory=True)
        unrelated = root / 'unrelated'; unrelated.mkdir()
        (unrelated / 'keep.txt').write_text('Keep this file when unregistering the folder.')
        welcome()
        press('Create New Project…')
        wait_for(lambda: control(identifier='project.name'), 'second project editor')
        type_text('Native Project B', identifier='project.name')
        choose_popup('Preset set', 'Client fixture')
        choose_path(parent, title='Choose Parent Folder…')
        wait_for(lambda: control(identifier='project.candidate-linked'), 'discovered Git worktree')
        assert control(identifier='project.candidate-alpha') and control(identifier='project.candidate-beta')
        press(identifier='project.candidate-beta')
        press(identifier='project.candidate-linked')
        press('Add Selected Repositories')
        choose_path(unrelated, title='Add Folder…')
        choose_path(unrelated, title='Add Folder…')
        press('Save Project')
        project_b = wait_for(lambda: next((p for p in records('projects') if p['name'] == 'Native Project B'), None), 'discovered project saved')
        expected_paths = {str(parent / 'beta'), str(parent / 'linked'), str(unrelated)}
        assert {f['canonicalPath'] for f in project_b['folders'] if f['registered']} == expected_paths
        assert len(project_b['folders']) == 3, 'Duplicate canonical folders must coalesce'
        assert project_b['presetSetID'] == project['presetSetID']
        summary['sharedSetAndNativeDiscoverySelection'] = True
        summary['gitFileAndSymlinkLoopDiscovery'] = True
        summary['addUnrelatedFolderAndDuplicateCoalescing'] = True
        print('Repository discovery, explicit selection and duplicate prevention passed', flush=True)

        wait_for(lambda: control(identifier='ellipsis.circle'), 'second project window')
        moved = root / 'moved-beta'; (parent / 'beta').rename(moved)
        folder_b = next(f for f in project_b['folders'] if f['canonicalPath'] == str(parent / 'beta'))
        folder_u = next(f for f in project_b['folders'] if f['canonicalPath'] == str(unrelated))
        project_actions('Project Settings…')
        wait_for(lambda: 'Missing or inaccessible' in text(), 'missing folder indicator')
        choose_path(moved, identifier='project.relink-' + folder_b['id'])
        press(identifier='project.remove-' + folder_u['id'])
        type_text('Native Project B renamed', identifier='project.name')
        press('Save Project')
        project_b = wait_for(lambda: next((p for p in records('projects') if p['id'] == project_b['id'] and p['name'] == 'Native Project B renamed'), None), 'relinked project saved')
        assert next(f for f in project_b['folders'] if f['id'] == folder_b['id'])['canonicalPath'] == str(moved)
        assert not next(f for f in project_b['folders'] if f['id'] == folder_u['id'])['registered']
        assert (unrelated / 'keep.txt').read_text() == 'Keep this file when unregistering the folder.'
        summary['nativeRenameRelinkAndUnregisterPreserveFiles'] = True
        ax('closeWindow', title='Native Project B renamed', role='AXWindow')
        welcome()
        project_menu(project_b['id'], 'Archive Project')
        wait_for(lambda: next(p for p in records('projects') if p['id'] == project_b['id'])['archived'], 'project archived')
        wait_for(lambda: not control(identifier='project-' + project_b['id']), 'archived project hidden')
        press('Archived', role='AXCheckBox')
        wait_for(lambda: control(identifier='project-' + project_b['id']), 'archived project shown')
        project_menu(project_b['id'], 'Reopen Project')
        wait_for(lambda: not next(p for p in records('projects') if p['id'] == project_b['id'])['archived'], 'project reopened')
        project_menu(project_b['id'], 'Open')
        wait_for(lambda: control('Native Project B renamed', role='AXWindow'), 'reopened project window')
        reopened = next(p for p in records('projects') if p['id'] == project_b['id'])
        assert reopened['folders'] == project_b['folders']
        summary['nativeProjectArchiveReopenPreservesMembership'] = True
        ax('closeWindow', title='Native Project B renamed', role='AXWindow')

        welcome()
        press('Create New Project…')
        wait_for(lambda: control(identifier='project.name'), 'third project editor')
        type_text('Native Project C', identifier='project.name')
        choose_popup('Preset set', 'Personal fixture')
        press('Start Empty')
        choose_path(unrelated, title='Add Folder…')
        press('Save Project')
        wait_for(lambda: len(records('projects')) == 3, 'three projects persisted')
        wait_for(lambda: control('New Session'), 'third project window')
        press('New Session')
        wait_for(lambda: control('Launch Session'), 'empty-set launch sheet')
        assert not control('Launch Session')['enabled'] and snapshot()['sessions'] == []
        dismiss_sheet()
        summary['emptySetCanSaveProjectButCannotLaunch'] = True
        ax('closeWindow', title='Native Project C', role='AXWindow')

        # The editor captures the record version at opening. A concurrent native
        # metadata save must not be silently overwritten by its stale values.
        settings()
        press(identifier='preset-set.edit')
        wait_for(lambda: control(identifier='preset-set.name'), 'set conflict editor')
        original_name = control(identifier='preset-set.name')['value']
        stored = next(r for r in snapshot()['store']['presetSets'] if r['value']['name'] == original_name)
        changed = dict(stored['value'], name=original_name + ' external')
        call('savePresetSet', {'record': changed, 'version': stored['version']})
        type_text(original_name + ' stale', identifier='preset-set.name')
        press('Save')
        wait_for(lambda: 'changed' in text().lower() or 'conflict' in text().lower(), 'stale editor error')
        assert next(s for s in records('presetSets') if s['id'] == stored['value']['id'])['name'] == changed['name']
        dismiss_sheet()
        summary['staleNativeEditorDoesNotOverwriteConcurrentSave'] = True
        summary['passed'] = True
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    except Exception:
        if pid:
            (artifacts / 'failed-controls.json').write_text(json.dumps(ax(), indent=2))
        (artifacts / 'failed-state.json').write_text(json.dumps(snapshot(), indent=2))
        if os.environ.get('CHAUFFEUR_HOLD_EDITOR_FAILURE') == '1':
            (artifacts / 'paused.json').write_text(json.dumps({'pid': pid, 'root': str(root)}))
            input('Fixture paused for inspection; press Return to clean up.\n')
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
