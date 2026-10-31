import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_inpen_terminal as helper


class ProjectUpdateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.current = (Path(__file__).resolve().parents[1] / 'FreeAPS.xcodeproj/project.pbxproj').read_text()
        # The fixture represents a newer personalized project with no external-insulin references.
        self.before_text = ''.join(line for line in self.current.splitlines(keepends=True)
                                   if not any(name in line for name in helper.SOURCE_FILES))
        self.before_text = self.before_text.replace('objectVersion = 54;', 'objectVersion = 60;')
        self.before_text = self.before_text.replace('/* Begin PBXBuildFile section */',
                                                   '/* Keep newer Siri and Watch work */\n/* Begin PBXBuildFile section */')
        self.project = self.repo / 'FreeAPS.xcodeproj' / 'project.pbxproj'
        self.project.parent.mkdir()
        self.project.write_text(self.before_text)

    def test_add_references_preserves_existing_objects_and_formatting(self):
        before = helper.read_project(self.project)
        proposed, expected = helper.plan_project(self.before_text, before)
        self.project.write_text(proposed)
        self.assertEqual(helper.read_project(self.project), expected)
        self.assertIn('/* Keep newer Siri and Watch work */\n', proposed)
        modified = [key for key, obj in before['objects'].items() if expected['objects'][key] != obj]
        self.assertEqual(len(modified), 2)
        self.assertEqual({before['objects'][key]['isa'] for key in modified}, {'PBXGroup', 'PBXSourcesBuildPhase'})
        self.assertEqual(len(expected['objects']) - len(before['objects']), 10)
        # Re-running does not add duplicate build entries or change formatting.
        second, second_model = helper.plan_project(proposed, expected)
        self.assertEqual(second, proposed)
        self.assertEqual(second_model, expected)

    def test_already_registered_project_is_unchanged(self):
        self.project.write_text(self.current)
        before = helper.read_project(self.project)
        proposed, expected = helper.plan_project(self.current, before)
        self.assertEqual(proposed, self.current)
        self.assertEqual(expected, before)

    def prepare_source_patch(self):
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        source = self.repo / 'example.swift'
        source.write_text('original\n')
        helper.git(self.repo, 'add', '.')
        helper.git(self.repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                   'commit', '-qm', 'fixture')
        source.write_text('updated\n')
        diff = helper.git(self.repo, 'diff', capture_output=True).stdout
        patch_file = self.repo / 'update.patch'
        patch_file.write_bytes(diff)
        source.write_text('original\n')
        result = self.repo / 'results'
        result.mkdir()
        return source, patch_file, result

    def test_source_conflict_does_not_touch_project_or_local_work(self):
        source, patch_file, result = self.prepare_source_patch()
        source.write_text('valuable current work\n')
        with self.assertRaises(RuntimeError):
            helper.apply_with_current_project(self.repo, patch_file, result)
        self.assertEqual(source.read_text(), 'valuable current work\n')
        self.assertEqual(self.project.read_text(), self.before_text)

    def test_project_write_failure_rolls_back_source_patch(self):
        source, patch_file, result = self.prepare_source_patch()
        with patch.object(helper.os, 'replace', side_effect=OSError('write refused')):
            with self.assertRaisesRegex(RuntimeError, 'rolled back'):
                helper.apply_with_current_project(self.repo, patch_file, result)
        self.assertEqual(source.read_text(), 'original\n')
        self.assertEqual(self.project.read_text(), self.before_text)

    def test_ambiguous_target_is_rejected(self):
        before = helper.read_project(self.project)
        target = next(obj for obj in before['objects'].values()
                      if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'FreeAPS')
        before['objects']['ABCDEF000000000000000001'] = copy.deepcopy(target)
        with self.assertRaisesRegex(RuntimeError, 'uniquely identify'):
            helper.plan_project(self.before_text, before)


if __name__ == '__main__':
    unittest.main()
