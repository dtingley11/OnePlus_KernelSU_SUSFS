"""Offline profile checks: python3 -m unittest discover -s tests -v (requires jq)."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / '.github/sm8845-lock.json').read_text())
WORKFLOW = (ROOT / '.github/workflows/build-kernel-release.yml').read_text()
TARGETS = {'OnePlus Ace 6T': ['OP-ACE-6T'], 'OnePlus 15R': ['OP15r'],
           'Both devices': ['OP-ACE-6T', 'OP15r']}


class SM8845Profile(unittest.TestCase):
    def test_json_and_minimal_configs(self):
        for path in (ROOT / 'configs').rglob('*.json'):
            json.loads(path.read_text())
        for model in LOCK['devices']:
            cfg = json.loads((ROOT / f'configs/a16/{model}.json').read_text())
            self.assertEqual((cfg['soc'], cfg['android_version'], cfg['kernel_version']),
                             ('canoe', 'android16', '6.12'))
            self.assertTrue(cfg['susfs'] and cfg['minimal'] and cfg['rust_build'])
            self.assertEqual(cfg['blacklist_modules'], '')
            self.assertEqual(cfg['lto'], 'stock')
            for flag in ['hmbird', 'opt', 'ds', 'bbg', 'bbr', 'bbr3', 'ttl',
                         'ip_set', 'unicode', 'ntsync']:
                self.assertFalse(cfg[flag], f'{model}: {flag}')

    def test_manifest_provenance(self):
        for dev in LOCK['devices'].values():
            root = ET.parse(ROOT / 'manifests/a16' / dev['manifest']).getroot()
            remotes = {r.get('name'): r.get('fetch') for r in root.findall('remote')}
            projects = root.findall('project')
            self.assertEqual(len(projects), 7)
            for project in projects:
                self.assertRegex(project.get('revision'), r'^[0-9a-f]{40}$')
                if project.get('name').startswith('android_kernel_'):
                    self.assertEqual(remotes[project.get('remote')], 'https://github.com/OnePlusOSS')
            by_path = {p.get('path'): p for p in projects}
            self.assertEqual(by_path['kernel_platform/common'].get('revision'), dev['common_commit'])
            self.assertEqual(by_path['./'].get('revision'), dev['modules_commit'])
            self.assertEqual(by_path['./'].get('name'),
                             'android_kernel_modules_and_devicetree_oneplus_sm8845')

    def test_patch_lock(self):
        for key in ['ksu', 'susfs', 'compatibility_patches']:
            self.assertRegex(LOCK[key]['commit'], r'^[0-9a-f]{40}$')
        patch = (ROOT / 'patches/sm8845/ksun-susfs.patch').read_bytes()
        self.assertEqual(hashlib.sha256(patch).hexdigest(),
                         LOCK['compatibility_patches']['adapted_patch_sha256'])
        self.assertEqual(LOCK['ksu']['version'], 30000 + 3239)
        self.assertEqual(LOCK['susfs']['version'], 'v2.2.0')

    def run_selection(self, selection):
        # Execute the actual workflow's shell through matrix composition, before
        # the network API calls. This catches quoting/jq errors in the real code.
        start = WORKFLOW.index('          set -euo pipefail', WORKFLOW.index('id: set-matrix'))
        end = WORKFLOW.index('          HEAD_REF=', start)
        script = textwrap.dedent(WORKFLOW[start:end])
        self.assertNotIn('${{', script)
        script += '\nprintf "%s\\n" "$merged_matrix" > selected.json\n'
        with tempfile.TemporaryDirectory() as folder:
            temp = Path(folder)
            (temp / 'configs').symlink_to(ROOT / 'configs', target_is_directory=True)
            (temp / '.github').symlink_to(ROOT / '.github', target_is_directory=True)
            result = subprocess.run(['bash', '-c', script], cwd=temp, text=True,
                                    env=dict(os.environ, DEVICE_SELECTION=selection,
                                             GITHUB_OUTPUT=str(temp / 'outputs')),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            selected = json.loads((temp / 'selected.json').read_text()) if result.returncode == 0 else None
            return result, selected

    def test_selection_and_default(self):
        self.assertIn('default: OnePlus Ace 6T', WORKFLOW)
        for selection, expected in TARGETS.items():
            with self.subTest(selection=selection):
                result, selected = self.run_selection(selection)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(sorted(x['model'] for x in selected), expected)
                for entry in selected:
                    self.assertEqual(entry['ksu_type'], 'KSUN')
                    self.assertEqual(entry['ksu_hash'], LOCK['ksu']['commit'])
                    self.assertTrue(entry['minimal'])
        for bad in ['A16', 'A14+15+16', 'android16-6.12', '', 'unexpected']:
            result, _ = self.run_selection(bad)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unknown device selection', result.stdout)

    def test_full_matrix_with_stubbed_revision_services(self):
        start = WORKFLOW.index('          set -euo pipefail', WORKFLOW.index('id: set-matrix'))
        end = WORKFLOW.index('      - name: Upload build matrix', start)
        code = textwrap.dedent(WORKFLOW[start:end])
        ksu_response = json.dumps({'data': {'repository': {'ho': {'o': LOCK['ksu']['commit']}}}})
        susfs_response = json.dumps({'data': {'project': {'repository': {
            'ch': {'sha': LOCK['susfs']['commit']},
            'blobs': {'nodes': [{'rawBlob': '#define SUSFS_VERSION "v2.2.0"'}]}}}}})
        for release in ['true', 'false']:
            with self.subTest(release=release), tempfile.TemporaryDirectory() as folder:
                temp = Path(folder)
                (temp / 'configs').symlink_to(ROOT / 'configs', target_is_directory=True)
                (temp / '.github').symlink_to(ROOT / '.github', target_is_directory=True)
                bindir = temp / 'bin'
                bindir.mkdir()
                for name, response in [('gh', ksu_response), ('curl', susfs_response)]:
                    stub = bindir / name
                    stub.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(response) + "\n")
                    stub.chmod(0o755)
                result = subprocess.run(['bash', '-c', code.replace('${{ inputs.make_release }}', release)],
                                        cwd=temp, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        env=dict(os.environ, DEVICE_SELECTION='Both devices',
                                                 PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                                                 GITHUB_OUTPUT=str(temp / 'outputs')))
                self.assertEqual(result.returncode, 0, result.stdout)
                outputs = dict(line.split('=', 1) for line in (temp / 'outputs').read_text().splitlines())
                matrix = json.loads(outputs['matrix'])['include']
                self.assertEqual(len(matrix), 2)
                self.assertEqual(outputs['active_gki_keys'], 'android16-6.12')
                for entry in matrix:
                    self.assertEqual(entry['ksu_resolved_hash'], LOCK['ksu']['commit'])
                    self.assertEqual(entry['susfs_resolved_hash'], LOCK['susfs']['commit'])
                if release == 'true':
                    self.assertEqual(outputs['susfs_base_version'], 'v2.2.0')

    def test_helper_syntax(self):
        for path in (ROOT / '.github/scripts').glob('*.sh'):
            subprocess.run(['bash', '-n', str(path)], check=True)


if __name__ == '__main__':
    unittest.main()
