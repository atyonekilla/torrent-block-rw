import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def report(rid, ip='203.0.113.5', node='node-a'):
    return {'id': rid, 'node': {'name': node}, 'report': {
        'xrayReport': {'protocol': 'bittorrent', 'source': ip + ':443'}}}


class BlockerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='torrent-blocker-test-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = dict(os.environ, TORRENT_BLOCKER_APP_DIR=str(self.path),
                        TORRENT_BLOCKER_STATE_DIR=str(self.path / 'state'),
                        TORRENT_BLOCKER_FIREWALL_LOCK=str(self.path / 'firewall.lock'))
        self.config = self.path / '.env'
        self.config.write_text('REMNAWAVE_API_BASE="https://example.invalid"\n'
                               'REMNAWAVE_API_TOKEN="dummy"\nINGRESS_NODE_NAME="test"\n'
                               'BAN_TIMEOUT="1h"\nPAGE_SIZE="2"\nMAX_PAGES="3"\n')
        (self.path / 'last_id').write_text('100\n')
        self.source = 'source ' + shlex.quote(str(ROOT / 'torrent-blocker')) + '\n'

    def run_bash(self, script, **kwargs):
        return subprocess.run(['bash', '-c', self.source + script], env=self.env,
                              capture_output=True, text=True, timeout=15, **kwargs)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def pages_run(self, pages, extra=''):
        for offset, payload in pages.items():
            if isinstance(payload, list):
                payload = {'response': {'records': payload}}
            (self.path / f'page-{offset}.json').write_text(json.dumps(payload))
        return self.run_bash('''
check_required_commands() { :; }
restore_bans() { :; }
fetch_page() { cat "$APP_DIR/page-$1.json"; }
process_report_record() {
  local id
  id="$(jq -r .id <<< "$1")"
  [[ "$id" != "${FAIL_ID:-}" ]] || return 1
  echo "$id" >> "$APP_DIR/processed"
}
''' + extra + '\nrun_blocker_once\n')

    def processed(self):
        p = self.path / 'processed'
        return p.read_text().splitlines() if p.exists() else []

    def test_complete_window_sorted_and_deduplicated(self):
        r = self.pages_run({0: [report(104), report(103)],
                            2: [report(103), report(102)], 4: [report(101), report(100)]})
        self.assert_ok(r)
        self.assertEqual(self.processed(), ['101', '102', '103', '104'])
        self.assertEqual((self.path / 'last_id').read_text().strip(), '104')

    def test_overflow_keeps_cursor_and_applies_nothing(self):
        r = self.pages_run({0: [report(107), report(106)], 2: [report(105), report(104)],
                            4: [report(103), report(102)]})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('превышено окно', r.stderr)
        self.assertEqual(self.processed(), [])
        self.assertEqual((self.path / 'last_id').read_text().strip(), '100')

    def test_bad_page_does_not_apply_earlier_page(self):
        for bad in [None, 'bad', 1.5, 9007199254740992]:
            with self.subTest(bad=bad):
                r = self.pages_run({0: [report(103), report(102)], 2: [report(101), report(bad)]})
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.processed(), [])
                self.assertEqual((self.path / 'last_id').read_text().strip(), '100')

    def test_wrong_schema_is_failure(self):
        r = self.pages_run({0: {'message': 'unexpected'}})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.processed(), [])

    def test_ascending_order_is_failure(self):
        r = self.pages_run({0: [report(101), report(102)]})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.processed(), [])

    def test_api_failure_keeps_cursor(self):
        r = self.pages_run({0: [report(103), report(102)]})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.processed(), [])

    def test_partial_apply_checkpoints_only_success(self):
        r = self.pages_run({0: [report(103), report(102)], 2: [report(101), report(100)]}, 'FAIL_ID=102')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.processed(), ['101'])
        self.assertEqual((self.path / 'last_id').read_text().strip(), '101')

    def test_large_page_does_not_exceed_argument_limit(self):
        # Enough JSON to exceed Linux's per-argument limit of roughly 128 KiB.
        self.config.write_text(self.config.read_text().replace('PAGE_SIZE="2"', 'PAGE_SIZE="500"'))
        records = [dict(report(n), padding='x' * 500) for n in range(600, 100, -1)]
        r = self.pages_run({0: records, 500: [report(100)]})
        self.assert_ok(r)
        self.assertEqual(len(self.processed()), 500)

    def test_corrupt_cursor_is_not_silently_reset(self):
        (self.path / 'last_id').write_text('garbage 100')
        r = self.pages_run({0: []})
        self.assertNotEqual(r.returncode, 0)

    def test_config_is_literal_and_roundtrips(self):
        self.env['TEST_VALUE'] = '$(touch SHOULD_NOT_EXIST) `id` $HOME "quoted" \\path'
        r = self.run_bash('''
write_config_file "$ENV_FILE" INGRESS_NODE_NAME "$TEST_VALUE"
load_config_file "$ENV_FILE"
[[ "$INGRESS_NODE_NAME" == "$TEST_VALUE" ]]
[[ "$(get_env INGRESS_NODE_NAME)" == "$TEST_VALUE" ]]
set_env INGRESS_NODE_NAME "$TEST_VALUE"
load_config_file "$ENV_FILE"
[[ "$INGRESS_NODE_NAME" == "$TEST_VALUE" ]]
''')
        self.assert_ok(r)
        self.assertFalse((ROOT / 'SHOULD_NOT_EXIST').exists())

    def test_existing_config_does_not_expand_commands(self):
        self.config.write_text('INGRESS_NODE_NAME="$(printf executed)"\n')
        r = self.run_bash('load_config_file "$ENV_FILE"; printf "%s" "$INGRESS_NODE_NAME"')
        self.assert_ok(r)
        self.assertEqual(r.stdout, '$(printf executed)')

    def test_config_rejects_shell_and_multiline(self):
        self.config.write_text('touch should-not-exist\n')
        self.assertNotEqual(self.run_bash('load_config_file "$ENV_FILE"').returncode, 0)
        self.assertNotEqual(self.run_bash('write_config_file "$ENV_FILE" INGRESS_NODE_NAME $\'a\\nb\'').returncode, 0)
        self.assertEqual(self.config.read_text(), 'touch should-not-exist\n')

    def test_timeout_validation(self):
        for timeout in ['0s', '00h', '-1m', '9999999d']:
            self.assertNotEqual(self.run_bash(f'validate_timeout {shlex.quote(timeout)}').returncode, 0)
        self.assert_ok(self.run_bash('validate_timeout 30m; [[ "$(timeout_seconds 30m)" == 1800 ]]'))

    def test_http_rejected(self):
        self.assertNotEqual(self.run_bash('validate_api_config http://example.invalid dummy').returncode, 0)

    def test_node_filter_and_allowlist(self):
        self.env['TEST_REPORT'] = json.dumps(report(101))
        r = self.run_bash('''
PROCESSED_COUNT=0; SKIPPED_COUNT=0; INGRESS_NODE_NAME=test; BAN_TIMEOUT=1h
ban_ip() { echo ban >> "$APP_DIR/processed"; }; logger() { :; }
REPORT_NODE_NAME=other
process_report_record "$TEST_REPORT"
REPORT_NODE_NAME=node-a; ALLOWLIST_IPV4=203.0.113.5
process_report_record "$TEST_REPORT"
[[ "$SKIPPED_COUNT" == 2 ]]
[[ ! -e "$APP_DIR/processed" ]]
ALLOWLIST_IPV4=''
process_report_record "$TEST_REPORT"
[[ "$PROCESSED_COUNT" == 1 ]]
''')
        self.assert_ok(r)
        self.assertEqual(self.processed(), ['ban'])

    def test_firewall_failure_propagates_from_record(self):
        self.env['TEST_REPORT'] = json.dumps(report(101))
        r = self.run_bash('''
PROCESSED_COUNT=0; SKIPPED_COUNT=0; INGRESS_NODE_NAME=test; BAN_TIMEOUT=1h
ban_ip() { return 1; }; logger() { :; }
if process_report_record "$TEST_REPORT"; then exit 99; fi
[[ "$PROCESSED_COUNT" == 0 ]]
''')
        self.assert_ok(r)

    def test_journal_restoration_expiry_and_no_shortening(self):
        r = self.run_bash('''
ensure_nft() { :; }
apply_ban_until() { printf '%s %s\\n' "$1" "$2" >> "$APP_DIR/applied"; }
logger() { :; }
ban_ip 203.0.113.5 1h
first="$(jq -r '."203.0.113.5"' "$BANS_FILE")"
ban_ip 203.0.113.5 1m
[[ "$(jq -r '."203.0.113.5"' "$BANS_FILE")" == "$first" ]]
# Simulate reboot by discarding applied kernel state; keep the journal.
rm "$APP_DIR/applied"
restore_bans
[[ "$(cat "$APP_DIR/applied")" == "203.0.113.5 $first" ]]
printf '{"203.0.113.5":1}' > "$BANS_FILE"
rm "$APP_DIR/applied"
restore_bans
[[ ! -e "$APP_DIR/applied" ]]
[[ "$(jq length "$BANS_FILE")" == 0 ]]
''')
        self.assert_ok(r)

    def test_corrupt_journal_does_not_change_firewall(self):
        (self.path / 'state').mkdir()
        (self.path / 'state/bans.json').write_text('{"999.0.0.1":9999999999}')
        r = self.run_bash('ensure_nft() { touch "$APP_DIR/changed"; }; restore_bans')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.path / 'changed').exists())

    def test_parallel_panels_preserve_both_bans(self):
        r = self.run_bash('''
ensure_nft() { :; }; apply_ban_until() { sleep 0.05; }; logger() { :; }
ban_ip 203.0.113.5 1h & a=$!
ban_ip 203.0.113.6 1h & b=$!
wait "$a"; wait "$b"
[[ "$(jq length "$BANS_FILE")" == 2 ]]
''')
        self.assert_ok(r)

    def test_failed_firewall_keeps_recoverable_intent(self):
        r = self.run_bash('''
ensure_nft() { :; }; apply_ban_until() { return 1; }
if ban_ip 203.0.113.5 1h; then exit 99; fi
jq -e '."203.0.113.5" > 0' "$BANS_FILE"
''')
        self.assert_ok(r)

    def test_prompt_without_terminal(self):
        r = self.run_bash('prompt_input "Token: " true', start_new_session=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('интерактивный терминал', r.stderr)
        self.assertNotIn('unbound variable', r.stderr)

    def test_prompt_pipe_hidden_stderr_and_secret(self):
        script = self.path / 'prompt.sh'
        script.write_text(self.source + '''
url="$(prompt_input 'URL: ')"
token="$(prompt_input 'Token: ' true)"
[[ "$url" == https://example.invalid && "$token" == dummy-secret ]]
echo DONE
''')
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe('bash', ['bash', '-c', f'cat {shlex.quote(str(script))} | bash 2>/dev/null'], self.env)
        output = b''
        sent_url = sent_token = False
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if b'URL: ' in output and not sent_url:
                    os.write(fd, b'https://example.invalid\n'); sent_url = True
                if b'Token: ' in output and not sent_token:
                    os.write(fd, b'dummy-secret\n'); sent_token = True
                ready, _, _ = select.select([fd], [], [], .05)
                if ready:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
            else:
                os.kill(pid, 9)
            _, status = os.waitpid(pid, 0)
        finally:
            os.close(fd)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output)
        self.assertIn(b'DONE', output)
        self.assertNotIn(b'dummy-secret', output)

    def test_fetch_validates_and_hides_token_from_arguments(self):
        self.env['TEST_PAYLOAD'] = json.dumps({'response': {'records': [report('101')]}})
        r = self.run_bash(r'''
curl() {
  local out='' header=''
  while (( $# )); do
    [[ "$1" != *dummy-secret* ]] || return 99
    case "$1" in
      -o) out="$2"; shift ;;
      -H) header="${2#@}"; shift ;;
    esac
    shift
  done
  [[ "$(stat -c %a "$header")" == 600 ]] || return 98
  grep -q 'Authorization: Bearer dummy-secret' "$header" || return 97
  printf '%s' "$TEST_PAYLOAD" > "$out"
  printf 200
}
fetch_reports https://example.invalid dummy-secret 100 0
''')
        self.assert_ok(r)
        self.assertEqual(json.loads(r.stdout)['response']['records'][0]['id'], 101)
        self.env['TEST_PAYLOAD'] = '{"message":"wrong schema"}'
        r = self.run_bash(r'''
curl() {
  while (( $# )); do
    if [[ "$1" == -o ]]; then printf '%s' "$TEST_PAYLOAD" > "$2"; shift; fi
    shift
  done
  printf 200
}
fetch_reports https://example.invalid dummy-secret 100 0
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, '')

    def test_both_config_writers_preserve_literal_token(self):
        self.env['TEST_TOKEN'] = '$(printf unsafe) "quote" `id` \\path'
        r = self.run_bash(r'''
write_panel_env_file "$ENV_FILE" sample sample.service sample.timer /tmp/menu https://example.invalid "$TEST_TOKEN" test 1h
load_config_file "$ENV_FILE"
[[ "$REMNAWAVE_API_TOKEN" == "$TEST_TOKEN" ]]
''')
        self.assert_ok(r)
        r = self.run_bash('source ' + shlex.quote(str(ROOT / 'install.sh')) + r'''
ENV_FILE="$TORRENT_BLOCKER_APP_DIR/.env"
INSTANCE_NAME=default; SERVICE_UNIT=test.service; TIMER_UNIT=test.timer; MENU_BIN=/tmp/menu
REMNAWAVE_API_BASE=https://example.invalid; REMNAWAVE_API_TOKEN="$TEST_TOKEN"
INGRESS_NODE_NAME=test; BAN_TIMEOUT=1h
write_env_file
load_config_file "$ENV_FILE"
[[ "$REMNAWAVE_API_TOKEN" == "$TEST_TOKEN" ]]
''')
        self.assert_ok(r)

    def test_real_nft_atomic_batch_in_isolated_namespace(self):
        available = subprocess.run(['unshare', '-Urn', 'nft', 'list', 'tables'], capture_output=True)
        if available.returncode:
            self.skipTest('unprivileged network namespace unavailable')
        script = self.source + '''
logger() { :; }
# Upgrade imports timed bans that predate the journal.
ensure_nft
nft add element inet torrent_guard blocked_ipv4 '{ 203.0.113.6 timeout 1h }'
restore_bans
jq -e '."203.0.113.6" > 0' "$BANS_FILE"
ban_ip 203.0.113.5 1h
ban_ip 203.0.113.5 1m
nft get element inet torrent_guard blocked_ipv4 '{ 203.0.113.5 }'
nft delete table inet torrent_guard
restore_bans
nft get element inet torrent_guard blocked_ipv4 '{ 203.0.113.5 }'
# A failing transaction must leave the old ban present.
if printf '%s\\n' 'delete element inet torrent_guard blocked_ipv4 { 203.0.113.5 }' \\
 'add element inet torrent_guard no_such_set { 203.0.113.5 }' | nft -f -; then exit 99; fi
nft get element inet torrent_guard blocked_ipv4 '{ 203.0.113.5 }'
'''
        r = subprocess.run(['unshare', '-Urn', 'bash', '-c', script], env=self.env,
                           capture_output=True, text=True, timeout=15)
        self.assert_ok(r)


if __name__ == '__main__':
    unittest.main()
