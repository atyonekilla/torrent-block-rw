import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='torrent-upgrade-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.units = self.root / 'systemd'
        self.bin = self.root / 'bin'
        self.release = self.root / 'release'
        for folder in [self.app, self.units, self.bin, self.release]:
            folder.mkdir()
        for file in ['torrent-blocker', 'common.sh']:
            shutil.copyfile(ROOT / file, self.release / file)
        self.old_script = b'#!/usr/bin/env bash\necho legacy-version\n'
        (self.app / 'torrent-blocker').write_bytes(self.old_script)
        (self.app / 'torrent-blocker').chmod(0o755)
        self.config = (b'# keep this exact legacy config\nREMNAWAVE_API_BASE="https://example.invalid"\n'
                       b'REMNAWAVE_API_TOKEN="dummy-token"\nBAN_TIMEOUT="6h"\n'
                       b'PAGE_SIZE="321"\nMAX_PAGES="12"\nINGRESS_NODE_NAME="my ingress"\n')
        (self.app / '.env').write_bytes(self.config)
        (self.app / '.env').chmod(0o600)
        (self.app / 'last_id').write_bytes(b'12345\n')
        (self.units / 'torrent-blocker.service').write_text('# custom service\n')
        (self.units / 'torrent-blocker.timer').write_text('# custom interval 42s\n')
        (self.units / 'torrent-blocker.service.d').mkdir()
        (self.units / 'torrent-blocker.service.d/custom.conf').write_text('# keep override\n')
        (self.units / 'other.service').write_text('# unrelated service\n')
        (self.root / 'bans.json').write_text('{"203.0.113.5":9999999999}')
        (self.root / 'timer-state').write_text('active')
        (self.root / 'timer-enabled').write_text('enabled')
        (self.root / 'menu').symlink_to(self.app / 'torrent-blocker')
        self.env = dict(os.environ, TEST_ROOT=str(self.root),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        for command in ['curl', 'nft']:
            file = self.bin / command
            file.write_text('#!/bin/sh\necho unexpected-call >> "$TEST_ROOT/external-calls"\nexit 99\n')
            file.chmod(0o755)
        # Fault injection at the actual rename boundary; rollback can then succeed.
        move = self.bin / 'mv'
        move.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
if sys.argv[-1] == os.environ.get('FAIL_RENAME') and not (root / 'rename-failed').exists():
    (root / 'rename-failed').touch()
    sys.exit(42)
os.execv('/usr/bin/mv', ['mv'] + sys.argv[1:])
''')
        move.chmod(0o755)
        self.setup = f'''source {shlex.quote(str(ROOT / 'common.sh'))}
source {shlex.quote(str(ROOT / 'install.sh'))}
APP_DIR="$TEST_ROOT/app"
ENV_FILE="$APP_DIR/.env"
INSTANCE_NAME=default
SERVICE_UNIT=torrent-blocker.service
TIMER_UNIT=torrent-blocker.timer
SERVICE_DST="$TEST_ROOT/systemd/$SERVICE_UNIT"
TIMER_DST="$TEST_ROOT/systemd/$TIMER_UNIT"
MENU_BIN="$TEST_ROOT/menu"
PROJECT_DIR="$TEST_ROOT/release"
systemctl() {{
  printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl.log"
  case "$1" in
    is-active) [[ "$(cat "$TEST_ROOT/timer-state")" == active ]] ;;
    stop) printf inactive > "$TEST_ROOT/timer-state" ;;
    start)
      if [[ "${{FAIL_START:-}}" == true && ! -f "$TEST_ROOT/start-failed" ]]; then
        touch "$TEST_ROOT/start-failed"
        return 1
      fi
      printf active > "$TEST_ROOT/timer-state"
      ;;
    daemon-reload)
      if [[ "${{FAIL_RELOAD:-}}" == true && ! -f "$TEST_ROOT/reload-failed" ]]; then
        touch "$TEST_ROOT/reload-failed"
        return 1
      fi
      ;;
    *) echo "Unexpected systemctl call: $*" >&2; return 99 ;;
  esac
}}
'''

    def run_script(self, code):
        return subprocess.run(['bash', '-c', self.setup + code], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def assert_preserved(self):
        self.assertEqual((self.app / '.env').read_bytes(), self.config)
        self.assertEqual((self.app / 'last_id').read_bytes(), b'12345\n')
        self.assertEqual((self.units / 'torrent-blocker.service').read_text(), '# custom service\n')
        self.assertEqual((self.units / 'torrent-blocker.timer').read_text(), '# custom interval 42s\n')
        self.assertEqual((self.units / 'torrent-blocker.service.d/custom.conf').read_text(), '# keep override\n')
        self.assertEqual((self.units / 'other.service').read_text(), '# unrelated service\n')
        self.assertEqual((self.root / 'bans.json').read_text(), '{"203.0.113.5":9999999999}')
        self.assertFalse((self.root / 'external-calls').exists())
        self.assertEqual(list(self.app.glob('.update.*')), [])

    def assert_rolled_back(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assertEqual((self.app / 'torrent-blocker').stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.app / 'common.sh').exists())
        self.assertTrue((self.root / 'menu').is_symlink())
        self.assertEqual((self.root / 'timer-state').read_text(), 'active')
        self.assert_preserved()

    def test_legacy_upgrade_preserves_data_units_and_active_timer(self):
        r = self.run_script('update_existing_installation\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), (ROOT / 'torrent-blocker').read_bytes())
        self.assertEqual((self.app / 'common.sh').read_bytes(), (ROOT / 'common.sh').read_bytes())
        self.assertIn('--menu', (self.root / 'menu').read_text())
        self.assertFalse((self.root / 'menu').is_symlink())
        self.assertEqual((self.root / 'timer-state').read_text(), 'active')
        self.assertEqual((self.root / 'timer-enabled').read_text(), 'enabled')
        backups = list((self.app / 'backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'config.env').read_bytes(), self.config)
        self.assertEqual((backups[0] / 'files/0').read_bytes(), self.old_script)
        self.assert_preserved()

    def test_disabled_inactive_timer_stays_disabled_inactive(self):
        (self.root / 'timer-state').write_text('inactive')
        (self.root / 'timer-enabled').write_text('disabled')
        r = self.run_script('update_existing_installation\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.root / 'timer-state').read_text(), 'inactive')
        self.assertEqual((self.root / 'timer-enabled').read_text(), 'disabled')
        log = (self.root / 'systemctl.log').read_text()
        self.assertNotIn('start ', log)
        self.assertNotIn('enable', log)
        self.assert_preserved()

    def test_disabled_but_active_timer_remains_active(self):
        (self.root / 'timer-enabled').write_text('disabled')
        r = self.run_script('update_existing_installation\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.root / 'timer-state').read_text(), 'active')
        self.assertEqual((self.root / 'timer-enabled').read_text(), 'disabled')
        self.assert_preserved()

    def test_failed_file_replacement_rolls_back_legacy_installation(self):
        self.env['FAIL_RENAME'] = str(self.root / 'menu')
        self.assert_rolled_back(self.run_script('update_existing_installation\n'))

    def test_failed_daemon_reload_rolls_back(self):
        self.env['FAIL_RELOAD'] = 'true'
        self.assert_rolled_back(self.run_script('update_existing_installation\n'))

    def test_failed_timer_start_rolls_back(self):
        self.env['FAIL_START'] = 'true'
        self.assert_rolled_back(self.run_script('update_existing_installation\n'))

    def test_bad_config_aborts_before_stopping_timer(self):
        self.config += b'BAN_TIMEOUT="0s"\n'
        (self.app / '.env').write_bytes(self.config)
        r = self.run_script('update_existing_installation\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assert_preserved()

    def test_missing_cursor_is_not_reset(self):
        (self.app / 'last_id').unlink()
        r = self.run_script('update_existing_installation\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.app / 'last_id').exists())
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)

    def test_repeat_update_keeps_configuration_and_cursor(self):
        for _ in range(2):
            r = self.run_script('update_existing_installation\n')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assert_preserved()
        self.assertEqual(len(list((self.app / 'backups').iterdir())), 2)

    def test_pipe_download_ignores_files_in_current_directory(self):
        r = self.run_script('''
INSTALL_FROM_STDIN=true
PROJECT_DIR="$APP_DIR"
cp "$TEST_ROOT/release/common.sh" "$APP_DIR/common.sh"
download_file() { cp "$TEST_ROOT/release/$1" "$2"; }
prepare_project_files
validate_project_files
[[ "$PROJECT_DIR" != "$APP_DIR" ]]
cmp "$PROJECT_DIR/torrent-blocker" "$TEST_ROOT/release/torrent-blocker"
''')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)

    def test_download_failure_keeps_old_installation(self):
        r = self.run_script('''
INSTALL_FROM_STDIN=true
download_file() { return 22; }
prepare_project_files
update_existing_installation
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assert_preserved()

    def test_old_menu_name_and_disabled_telegram_keys_are_preserved(self):
        legacy_menu = self.root / 'menu-menu'
        legacy_menu.symlink_to(self.app / 'torrent-blocker')
        self.config += (f'MENU_BIN="{legacy_menu}"\n'.encode() +
                        b'TELEGRAM_ENABLED="false"\nTELEGRAM_BOT_TOKEN=""\n'
                        b'TELEGRAM_CHAT_ID=""\nTELEGRAM_TOPIC_ID=""\n')
        (self.app / '.env').write_bytes(self.config)
        r = self.run_script('update_existing_installation\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('--menu', legacy_menu.read_text())
        self.assertIn('--menu', (self.root / 'menu').read_text())
        self.assert_preserved()

    def test_enabled_legacy_telegram_does_not_silently_lose_notifications(self):
        self.config += b'TELEGRAM_ENABLED="true"\n'
        (self.app / '.env').write_bytes(self.config)
        r = self.run_script('update_existing_installation\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Telegram', r.stderr)
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assert_preserved()

    def test_invalid_download_aborts_before_stopping_timer(self):
        (self.release / 'torrent-blocker').write_text('if then broken')
        r = self.run_script('validate_project_files\nupdate_existing_installation\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assert_preserved()

    def test_masked_timer_is_preserved(self):
        timer = self.units / 'torrent-blocker.timer'
        timer.unlink()
        timer.symlink_to('/dev/null')
        (self.root / 'timer-state').write_text('inactive')
        (self.root / 'timer-enabled').write_text('masked')
        r = self.run_script('update_existing_installation\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(timer.is_symlink())
        self.assertEqual(os.readlink(timer), '/dev/null')
        self.assertEqual((self.root / 'timer-state').read_text(), 'inactive')
        self.assertEqual((self.root / 'timer-enabled').read_text(), 'masked')
        self.assertNotIn('start ', (self.root / 'systemctl.log').read_text())

    def test_foreign_service_name_aborts_without_touching_units(self):
        self.config += b'SERVICE_UNIT="other.service"\n'
        (self.app / '.env').write_bytes(self.config)
        r = self.run_script('update_existing_installation\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assertEqual((self.app / 'torrent-blocker').read_bytes(), self.old_script)
        self.assert_preserved()

    def test_pipe_entrypoint_runs_without_bash_source(self):
        # Exit at the root check, before any real install commands can execute.
        r = subprocess.run(['bash'], input='id() { echo 1000; }\n' + (ROOT / 'install.sh').read_text(),
                           env=self.env, text=True, capture_output=True, timeout=5)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('от root', r.stdout)
        self.assertNotIn('unbound variable', r.stderr)

    def test_readonly_check_does_not_touch_state(self):
        r = self.run_script('TORRENT_BLOCKER_APP_DIR="$APP_DIR" bash "$PROJECT_DIR/torrent-blocker" --check-config\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assert_preserved()


if __name__ == '__main__':
    unittest.main()
