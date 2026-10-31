#!/usr/bin/env python3
"""Preserve a Mac checkout, apply the reviewed draft, and build without installing."""
import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=str(Path.home() / 'iAPS'))
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('Run this helper in Terminal on your Mac.')
    os.umask(0o077)
    repo = resolve_repo(args.repo)
    if git(repo, 'ls-files', '-u', capture_output=True).stdout:
        raise RuntimeError('An existing merge has unresolved files. Nothing changed.')
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
        git(repo, 'diff', '--binary', BASE, DRAFT, stdout=output)
    try:
        status = apply_checked(repo, patch)
    except RuntimeError as error:
        (result / 'RESULT.txt').write_text(str(error) + '\nBackup: ' + str(result) + '\n')
        print(str(error), flush=True)
        print('Send RESULT.txt when convenient: ' + str(result / 'RESULT.txt'), flush=True)
        return 2
    print('Draft ' + status + '. Your existing branch and local changes are preserved.', flush=True)
    locations = subprocess.run(['mdfind', '-name', 'MetabolicTwin'], capture_output=True, text=True)
    (result / 'MetabolicTwin-locations.txt').write_text(locations.stdout)
    log = result / 'build.log'
    print('Running an unsigned build check; this can take several minutes.', flush=True)
    print('Build log: ' + str(log), flush=True)
    with log.open('w') as output:
        build = subprocess.run([
            'xcodebuild', '-workspace', 'FreeAPS.xcworkspace', '-scheme', 'FreeAPS',
            '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
            '-derivedDataPath', str(result / 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO', 'build'
        ], cwd=repo, stdout=output, stderr=subprocess.STDOUT)
    summary = ('BUILD CHECK PASSED' if build.returncode == 0 else 'BUILD CHECK NEEDS REVIEW')
    details = [summary, 'Source draft: ' + status, 'Backup/results: ' + str(result),
               'Phone app was not installed or replaced.',
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


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print('STOPPED: ' + str(error), file=sys.stderr)
        sys.exit(1)
