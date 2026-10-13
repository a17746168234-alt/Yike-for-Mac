"""Exercise installer process exit, replacement and failure markers in isolated fixtures."""
from pathlib import Path
import plistlib, shutil, subprocess, tempfile, threading, unittest

ROOT=Path(__file__).resolve().parents[2]

class InstallerTests(unittest.TestCase):
    def run_case(self, bad_signature):
        with tempfile.TemporaryDirectory(dir=ROOT/'work', prefix='installer-test-') as directory:
            root=Path(directory)
            old=root/'current/Yike.app'; new=root/'new/Yike.app'
            for app, version in [(old,'77'),(new,'79')]:
                (app/'Contents').mkdir(parents=True)
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cn.yike.fixture'}))
                (app/'version').write_text(version)
            if bad_signature: (new/'bad-signature').touch()
            marker=root/'support/yike-update-failed'; marker.parent.mkdir(); marker.touch()
            stage=root/'stage'; stage.mkdir(); dmg=stage/'Yike.dmg'; dmg.touch()
            hdi=root/'hdiutil'
            hdi.write_text('#!/usr/bin/env python3\nimport sys,shutil\nfrom pathlib import Path\n'
                f'new=Path({str(new)!r})\n'
                'if sys.argv[1]=="attach": shutil.copytree(new,Path(sys.argv[-1])/"Yike.app")\n'
                'if sys.argv[1]=="detach": shutil.rmtree(Path(sys.argv[2])/"Yike.app",ignore_errors=True)\n')
            hdi.chmod(0o755)
            sign=root/'codesign'; sign.write_text('#!/bin/zsh\nfor arg in "$@"; do target="$arg"; done\n[[ ! -f "$target/bad-signature" ]]\n'); sign.chmod(0o755)
            script=(ROOT/'native/UpdateInstaller.sh').read_text()
            script=script.replace('/usr/bin/hdiutil',str(hdi)).replace('/usr/bin/codesign',str(sign))
            script=script.replace('log_dir="$HOME/Library/Logs/Yike"',f'log_dir="{root}/logs"')
            script=script.replace('/tmp/yike-update-mount.',str(root)+'/mount.').replace('/tmp/yike-update-backup.',str(root)+'/backup.')
            helper=root/'install.sh'; helper.write_text(script)
            sleeper=subprocess.Popen(['/bin/sleep','60'])
            reaper=threading.Thread(target=sleeper.wait,daemon=True); reaper.start()
            try:
                result=subprocess.run(['/bin/zsh',str(helper),str(sleeper.pid),str(dmg),str(old),'cn.yike.fixture',str(marker),'0'],timeout=25)
                reaper.join(2)
                self.assertIsNotNone(sleeper.poll(), 'installer must stop the exact old process')
                self.assertEqual(result.returncode,1 if bad_signature else 0)
                self.assertEqual((old/'version').read_text(),'77' if bad_signature else '79')
                self.assertEqual(marker.exists(),bad_signature)
                self.assertIn('sending TERM',(root/'logs/updater.log').read_text())
                if not bad_signature: self.assertIn('app left closed',(root/'logs/updater.log').read_text())
            finally:
                if sleeper.poll() is None: sleeper.terminate(); sleeper.wait()

    def test_stalled_old_process_is_stopped_and_stale_marker_cleared(self): self.run_case(False)
    def test_bad_package_preserves_old_app_and_records_failure(self): self.run_case(True)

if __name__=='__main__': unittest.main()
