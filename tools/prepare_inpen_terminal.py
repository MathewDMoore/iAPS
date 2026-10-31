#!/usr/bin/env python3
"""Preserve a Mac checkout, apply the reviewed draft, and build without installing."""
import argparse
import copy
import hashlib
import json
import re
import shutil
import tempfile
import datetime
import os
from pathlib import Path
import platform
import subprocess
import sys

BASE = 'f2fe90a4c8d0c6adbe838d76ce5f8c38c4b66d51'
DRAFT = '568a276b1aabde0f2c424771e076dc55c6921572'


def git(repo, *args, **kwargs):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, **kwargs)


def resolve_repo(requested):
    repo = Path(requested).expanduser().resolve()
    root = Path(git(repo, 'rev-parse', '--show-toplevel', capture_output=True, text=True).stdout.strip())
    # APFS commonly ignores case; pathlib string equality does not.
    if not root.samefile(repo):
        raise RuntimeError('Run from the iAPS Git root. Detected Git root: ' + str(root))
    if not (root / 'FreeAPS.xcodeproj' / 'project.pbxproj').is_file():
        raise RuntimeError('FreeAPS.xcodeproj/project.pbxproj was not found in ' + str(root))
    return root.resolve()


def apply_checked(repo, patch):
    """Check the entire patch before touching source; no stash/reset/index mutation."""
    check = subprocess.run(['git', '-C', str(repo), 'apply', '--check', str(patch)],
                           capture_output=True, text=True)
    if check.returncode:
        reverse = subprocess.run(['git', '-C', str(repo), 'apply', '--reverse', '--check', str(patch)],
                                 capture_output=True, text=True)
        if reverse.returncode == 0:
            return 'already applied'
        raise RuntimeError('Draft needs a manual merge; no source files were changed.\n' + check.stderr)
    git(repo, 'apply', str(patch))
    return 'applied'


SOURCE_FILES = (
    'ExternalInsulinRecord.swift', 'ExternalInsulinStore.swift', 'ExternalInsulinView.swift',
    'InPenBluetoothReader.swift', 'InPenRecordDecoder.swift',
)


def read_project(path):
    parsed = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)],
                            capture_output=True, text=True)
    if parsed.returncode:
        raise RuntimeError('Could not verify Xcode project: ' + (parsed.stderr or parsed.stdout).strip())
    return json.loads(parsed.stdout)


def add_array_entries(text, object_id, key, entries):
    if not entries:
        return text
    # Xcode object blocks close at the same indentation as their object identifier.
    pattern = r'(?ms)^([ \t]*)' + re.escape(object_id) + r'\b[^\n]*=\s*\{\n.*?^\1\};'
    match = re.search(pattern, text)
    if not match:
        raise RuntimeError('Cannot locate Xcode object ' + object_id + '; nothing was applied.')
    block = match.group(0)
    array = re.search(r'(?m)^([ \t]*)' + re.escape(key) + r'\s*=\s*\(\s*\n', block)
    if not array:
        raise RuntimeError('Cannot locate Xcode ' + key + ' list; nothing was applied.')
    insert = ''.join(array.group(1) + '\t' + entry + ',\n' for entry in entries)
    block = block[:array.end()] + insert + block[array.end():]
    return text[:match.start()] + block + text[match.end():]


def plan_project(text, before):
    """Add only new source references to the current app target; keep other objects intact."""
    expected = copy.deepcopy(before)
    objects = expected['objects']
    targets = [obj for obj in objects.values()
               if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'FreeAPS'
               and obj.get('productType') == 'com.apple.product-type.application']
    if len(targets) != 1:
        raise RuntimeError('Cannot uniquely identify the FreeAPS app target; nothing was applied.')
    phases = [key for key in targets[0]['buildPhases']
              if objects[key].get('isa') == 'PBXSourcesBuildPhase']
    if len(phases) != 1:
        raise RuntimeError('Cannot uniquely identify the app source phase; nothing was applied.')
    phase_id = phases[0]
    group_id = objects[expected['rootObject']]['mainGroup']
    if objects[group_id].get('isa') != 'PBXGroup':
        raise RuntimeError('Unsupported Xcode main group; nothing was applied.')
    new_refs, new_builds, group_entries, phase_entries = [], [], [], []
    for name in SOURCE_FILES:
        path = 'FreeAPS/Sources/Modules/ExternalInsulin/' + name
        refs = [key for key, obj in objects.items()
                if obj.get('isa') == 'PBXFileReference' and obj.get('path') == path]
        if len(refs) > 1:
            raise RuntimeError('Duplicate Xcode source references for ' + name + '; nothing was applied.')
        if refs:
            fid = refs[0]
        else:
            # Fail on a differently grouped source with the same name rather than guessing its path.
            if any(obj.get('isa') == 'PBXFileReference' and
                   (obj.get('name') == name or str(obj.get('path', '')).endswith('/' + name)
                    or obj.get('path') == name) for obj in objects.values()):
                raise RuntimeError('An existing Xcode reference for ' + name + ' needs review; nothing was applied.')
            fid = hashlib.sha1(('external-ref-' + name).encode()).hexdigest()[:24].upper()
            if fid in objects:
                raise RuntimeError('Xcode identifier collision; nothing was applied.')
            objects[fid] = dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift',
                                name=name, path=path, sourceTree='<group>')
            new_refs.append('\t\t' + fid + ' /* ' + name + ' */ = {isa = PBXFileReference; '
                            'lastKnownFileType = sourcecode.swift; name = ' + name + '; path = ' + path +
                            '; sourceTree = "<group>"; };\n')
        if fid not in objects[group_id]['children']:
            objects[group_id]['children'].insert(0, fid)
            group_entries.insert(0, fid + ' /* ' + name + ' */')
        matching = [key for key in objects[phase_id]['files'] if objects[key].get('fileRef') == fid]
        if len(matching) > 1:
            raise RuntimeError('Duplicate app source build entries; nothing was applied.')
        if not matching:
            bid = hashlib.sha1(('external-build-' + name).encode()).hexdigest()[:24].upper()
            if bid in objects:
                if objects[bid] != dict(isa='PBXBuildFile', fileRef=fid):
                    raise RuntimeError('Xcode build identifier collision; nothing was applied.')
            else:
                objects[bid] = dict(isa='PBXBuildFile', fileRef=fid)
                new_builds.append('\t\t' + bid + ' /* ' + name + ' in Sources */ = {isa = PBXBuildFile; '
                                  'fileRef = ' + fid + ' /* ' + name + ' */; };\n')
            objects[phase_id]['files'].insert(0, bid)
            phase_entries.insert(0, bid + ' /* ' + name + ' in Sources */')
    for section, entries in [('PBXFileReference', new_refs), ('PBXBuildFile', new_builds)]:
        if entries:
            marker = '/* Begin ' + section + ' section */\n'
            if text.count(marker) != 1:
                raise RuntimeError('Unsupported Xcode project formatting; nothing was applied.')
            text = text.replace(marker, marker + ''.join(entries), 1)
    text = add_array_entries(text, group_id, 'children', group_entries)
    text = add_array_entries(text, phase_id, 'files', phase_entries)
    return text, expected


def apply_with_current_project(repo, patch, result):
    project = repo / 'FreeAPS.xcodeproj' / 'project.pbxproj'
    original = project.read_bytes()
    proposed, expected = plan_project(original.decode(), read_project(project))
    prepared = result / 'proposed-project.pbxproj'
    prepared.write_text(proposed)
    if read_project(prepared) != expected:
        raise RuntimeError('Project verification failed; nothing was applied.')
    if project.read_bytes() != original:
        raise RuntimeError('The Xcode project changed during preparation; nothing was applied.')
    # Keep the project formatting and all original objects; only the verified references are added.
    status = apply_checked(repo, patch)
    if proposed.encode() != original:
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(dir=project.parent, delete=False) as output:
                tmp = Path(output.name)
                output.write(proposed.encode())
                output.flush()
                os.fsync(output.fileno())
            shutil.copymode(project, tmp)
            if project.read_bytes() != original:
                raise RuntimeError('The Xcode project changed before the write.')
            os.replace(tmp, project)
        except (OSError, RuntimeError):
            if tmp is not None:
                tmp.unlink(missing_ok=True)
            if status == 'applied':
                git(repo, 'apply', '--reverse', '--check', str(patch))
                git(repo, 'apply', '--reverse', str(patch))
            raise RuntimeError('Project update stopped; the source patch was rolled back. Backup: ' + str(result))
    return status


def select_scheme(schemes):
    for name in ('FreeAPS', 'FreeAPSWorkspace', 'iAPS'):
        if name in schemes:
            return name
    raise RuntimeError('No recognized app scheme was found. Available schemes: ' + ', '.join(schemes))


def discover_scheme(repo, result):
    print('Reading the schemes available in your workspace...', flush=True)
    listed = subprocess.run(['xcodebuild', '-workspace', 'FreeAPS.xcworkspace', '-list', '-json'],
                            cwd=repo, capture_output=True, text=True)
    (result / 'workspace-schemes.log').write_text(listed.stdout + '\n' + listed.stderr)
    if listed.returncode:
        raise RuntimeError('Could not list workspace schemes. See ' + str(result / 'workspace-schemes.log'))
    # Package-resolution messages can precede xcodebuild's JSON payload.
    decoder = json.JSONDecoder()
    for match in re.finditer(r'\{', listed.stdout):
        try:
            payload, _ = decoder.raw_decode(listed.stdout[match.start():])
        except ValueError:
            continue
        if isinstance(payload, dict) and isinstance(payload.get('workspace'), dict):
            schemes = payload['workspace'].get('schemes', [])
            return select_scheme(schemes)
    raise RuntimeError('Workspace schemes could not be decoded. See ' + str(result / 'workspace-schemes.log'))


def run_build(repo, result, status, retry=False):
    suffix = '-retry-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') if retry else ''
    log = result / ('build' + suffix + '.log')
    try:
        scheme = discover_scheme(repo, result)
    except RuntimeError as error:
        (result / 'RESULT.txt').write_text(str(error) + '\nNo source files were changed by this build attempt.\n')
        print(str(error), flush=True)
        return 2
    print('Using workspace scheme: ' + scheme, flush=True)
    print('Running an unsigned build check; this can take several minutes.', flush=True)
    print('Build log: ' + str(log), flush=True)
    with log.open('w') as output:
        build = subprocess.run([
            'xcodebuild', '-workspace', 'FreeAPS.xcworkspace', '-scheme', scheme,
            '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
            '-derivedDataPath', str(result / 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO', 'build'
        ], cwd=repo, stdout=output, stderr=subprocess.STDOUT)
    summary = 'BUILD CHECK PASSED' if build.returncode == 0 else 'BUILD CHECK NEEDS REVIEW'
    details = [summary, 'Source draft: ' + status, 'Workspace scheme: ' + scheme,
               'Backup/results: ' + str(result), 'Phone app was not installed or replaced.',
               'MetabolicTwin locations: ' + str(result / 'MetabolicTwin-locations.txt'),
               'Build log: ' + str(log)]
    if build.returncode:
        lines = log.read_text(errors='replace').splitlines()
        errors = [line for line in lines if 'error:' in line or 'BUILD FAILED' in line]
        details += errors[:15] if errors else lines[-15:]
    (result / 'RESULT.txt').write_text('\n'.join(details) + '\n')
    print('\n'.join(details), flush=True)
    print('When convenient, share RESULT.txt and MetabolicTwin-locations.txt.', flush=True)
    return build.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=str(Path.home() / 'iAPS'))
    parser.add_argument('--build-only', action='store_true', help='Retry compilation without applying source changes')
    parser.add_argument('--results', type=Path, help='Existing backup/results folder for a build retry')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('Run this helper in Terminal on your Mac.')
    os.umask(0o077)
    repo = resolve_repo(args.repo)
    if git(repo, 'ls-files', '-u', capture_output=True).stdout:
        raise RuntimeError('An existing merge has unresolved files. Nothing changed.')
    if args.build_only:
        if args.results is None or not args.results.expanduser().is_dir():
            raise RuntimeError('--build-only requires the existing --results folder.')
        if not all((repo / 'FreeAPS/Sources/Modules/ExternalInsulin' / name).is_file() for name in SOURCE_FILES):
            raise RuntimeError('The external insulin source draft is not fully applied; no build was attempted.')
        project = repo / 'FreeAPS.xcodeproj/project.pbxproj'
        text = project.read_text()
        proposed, _ = plan_project(text, read_project(project))
        if proposed != text:
            raise RuntimeError('External insulin project references are incomplete; no source changes were made.')
        return run_build(repo, args.results.expanduser().resolve(), 'already applied (build retry)', retry=True)
    git(repo, 'cat-file', '-e', DRAFT + '^{commit}')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    result = Path.home() / 'Desktop' / ('iAPS-InPen-' + stamp)
    result.mkdir(parents=True, mode=0o700)
    print('Backup and results: ' + str(result), flush=True)
    for filename, command in [('git-status.txt', ['status', '--short']),
                              ('git-head.txt', ['rev-parse', 'HEAD']),
                              ('local-changes.patch', ['diff', '--binary', 'HEAD'])]:
        with (result / filename).open('wb') as output:
            git(repo, *command, stdout=output)
    print('Backing up source, including current uncommitted changes...', flush=True)
    subprocess.run(['tar', '-czf', str(result / 'source-before.tgz'),
                    '--exclude=./.git', '--exclude=./build', '--exclude=./DerivedData',
                    '--exclude=./.build', '-C', str(repo), '.'], check=True)
    patch = result / 'reviewed-inpen-draft.patch'
    with patch.open('wb') as output:
        git(repo, 'diff', '--binary', BASE, DRAFT, '--', '.',
            ':(exclude)FreeAPS.xcodeproj/project.pbxproj', stdout=output)
    try:
        status = apply_with_current_project(repo, patch, result)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        (result / 'RESULT.txt').write_text(str(error) + '\nBackup: ' + str(result) + '\n')
        print(str(error), flush=True)
        print('Send RESULT.txt when convenient: ' + str(result / 'RESULT.txt'), flush=True)
        return 2
    print('Draft ' + status + '. Your existing branch and local changes are preserved.', flush=True)
    locations = subprocess.run(['mdfind', '-name', 'MetabolicTwin'], capture_output=True, text=True)
    (result / 'MetabolicTwin-locations.txt').write_text(locations.stdout)
    return run_build(repo, result, status)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print('STOPPED: ' + str(error), file=sys.stderr)
        sys.exit(1)
