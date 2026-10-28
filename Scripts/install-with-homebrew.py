#!/usr/bin/env python3
"""Install the reviewed local package through the existing Homebrew cask."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import plistlib
import signal
import subprocess
import sys
import time
import tempfile
import shutil
import argparse

root = Path(__file__).resolve().parent.parent
arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument('--prepare', action='store_true')
arguments.add_argument('--plan', type=Path, default=root/'build/homebrew-install-plan.json')
options = arguments.parse_args()
build = options.plan.resolve().parent
plan = json.loads(options.plan.read_text())
recipe = Path(plan['recipe'])
original = (build / 'horndis-homebrew-original.rb').read_bytes()
local = (build / 'horndis-homebrew-local.rb').read_bytes()
package = Path(plan['package'])
prepare = options.prepare
brew = plan.get('brew', shutil.which('brew') or '/opt/homebrew/bin/brew')
cask_token = plan.get('cask', 'jlikeme/tap/horndis')
env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_INSTALL_CLEANUP='1')
record = {'started_at': time.time(), 'prepare_only': prepare, 'package': str(package)}
migration = None
recipe_baseline = recipe.read_bytes()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def snapshot(path):
    if not path.exists():
        return None
    stat = path.stat()
    return {'sha256': digest(path.read_bytes()), 'mtime_ns': stat.st_mtime_ns, 'inode': stat.st_ino}

assert digest(original) == plan['original_sha256']
assert digest(local) == plan['local_sha256']
assert digest(package.read_bytes()) == plan['package_sha256']
assert recipe_baseline in [original, local], 'The cask changed; refusing to overwrite it.'
recipe_stat = recipe.stat()
protected = [Path(path) for path in plan.get('protected_files', [])]
before = {str(path): snapshot(path) for path in protected}
settings_path = Path.home() / 'Library/Application Support/HoRNDIS/Surge/settings.json'
settings_before = settings_path.read_bytes() if settings_path.exists() else None

def network_snapshot():
    preferences = plistlib.loads(Path('/Library/Preferences/SystemConfiguration/preferences.plist').read_bytes())
    bridges = {name: value.get('Options', {}) for name, value in
               preferences.get('VirtualNetworkInterfaces', {}).get('Bridge', {}).items()
               if value.get('Options', {}).get('HoRNDISOwner') == 'io.github.noahhhi.horndis.network-v1'}
    identifiers = sorted({value.get('HoRNDISServiceID') for value in bridges.values() if value.get('HoRNDISServiceID')})
    services = preferences.get('NetworkServices', {})
    return {'service_ids': identifiers, 'owned_bridge_options': bridges,
            'service_configuration_sha256': {key: digest(plistlib.dumps(services.get(key, {}), sort_keys=True)) for key in identifiers},
            'orders': {key: value.get('Network', {}).get('Global', {}).get('IPv4', {}).get('ServiceOrder', [])
                       for key, value in preferences.get('Sets', {}).items()}}

network_before = network_snapshot()

def restore_integration_preferences():
    # Homebrew reinstall runs the normal uninstaller, which intentionally turns
    # integration off for cleanup. Restore the user's preferences for this upgrade.
    if settings_before is None:
        return
    desired = json.loads(settings_before)
    current_bytes = settings_path.read_bytes()
    if current_bytes == settings_before:
        record['integration_preferences_preserved'] = True
        return
    current = json.loads(current_bytes)
    def user_values(value):
        result = {key: item for key, item in value.items() if key not in ['enabled', 'autoStartUSB', 'revision', 'cleanupRevision']}
        result.setdefault('switchIntelligence', False)
        result.setdefault('adbPath', '')
        result.setdefault('adbRetryToken', '')
        result.setdefault('adbPausedProcessID', None)
        return result
    if user_values(current) != user_values(desired) or current.get('enabled') != False or current.get('autoStartUSB', False):
        record['integration_preferences_preserved'] = 'Concurrent user edit retained'
        return
    descriptor, temporary = tempfile.mkstemp(prefix='.horndis-upgrade-', dir=str(settings_path.parent))
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(settings_before)
        os.replace(temporary, settings_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    record['integration_preferences_preserved'] = True
    subprocess.run(['/Applications/HoRNDIS Status.app/Contents/MacOS/horndis-status', 'restart'], check=True)

def interrupted(signum, frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
exit_code = 1
try:
    recipe.write_bytes(local)
    information = subprocess.run([brew, 'info', '--cask', '--json=v2', cask_token],
                                 env=env, capture_output=True, text=True, check=True)
    cask = json.loads(information.stdout)['casks'][0]
    assert cask['url'] == package.as_uri()
    assert cask['sha256'] == plan['package_sha256']
    assert cask['full_token'] == cask_token
    record['cask'] = cask['full_token']
    print('预检查临时使用配套 cask，结束后恢复原定义。' if prepare else
          'Homebrew 将保留网络服务并重装；成功后保留配套 cask，旧定义已有备份。', flush=True)
    if prepare:
        result = subprocess.run([brew, 'fetch', '--cask', cask_token], env=env)
    else:
        print('若提示 Password，请在此终端输入 macOS 管理员密码；输入不会显示。', flush=True)
        # `install --force` still skips an already-installed cask with the same
        # version. Explicit reinstall runs the package and its service setup.
        record['install_mode'] = 'reinstall'
        # Legacy Homebrew receipts still name the old unconditional uninstaller.
        # Adapt both its receipt and caskfile before Homebrew starts cleanup.
        source = Path(plan['source_app'])
        reviewed = source / 'Contents/Resources/horndis-uninstall'
        assert digest(reviewed.read_bytes()) == plan['compatibility_uninstaller_sha256']
        compatibility = build / 'homebrew-maintenance-compat' / 'horndis-uninstall'
        compatibility.parent.mkdir(mode=0o700, exist_ok=True)
        shutil.copyfile(reviewed, compatibility)
        compatibility.chmod(0o700)
        specification = importlib.util.spec_from_file_location('horndis_maintenance', root/'Scripts/homebrew-maintenance.py')
        maintenance = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(maintenance)
        caskroom = plan.get('caskroom') or subprocess.run([brew, '--caskroom', 'horndis'], capture_output=True, text=True, check=True).stdout.strip()
        migration = maintenance.InstalledCaskMigration(caskroom, compatibility,
                                                     build/'homebrew-maintenance-backups')
        record['legacy_cask_migration'] = migration.prepare()
        result = subprocess.run([brew, 'reinstall', '--cask', '--require-sha', cask_token], env=env)
    exit_code = result.returncode
    record['brew_exit_code'] = exit_code
    if not prepare and exit_code == 0:
        installed = Path('/Applications/HoRNDIS Status.app')
        source = Path(plan.get('source_app', str(build / 'universal/HoRNDISStatus.app')))
        installed_info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
        source_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
        record['installed_bundle_build'] = installed_info['CFBundleVersion']
        expected_build = source_info['CFBundleVersion']
        if installed_info['CFBundleVersion'] != expected_build:
            raise RuntimeError('Homebrew 未替换应用：当前 build ' + installed_info['CFBundleVersion']
                               + '，需要 build ' + expected_build + '。')
        matches = {}
        for relative in ['Contents/MacOS/horndis-status', 'Contents/Helpers/horndis-surge-agent',
                         'Contents/Resources/horndis', 'Contents/Resources/horndis-uninstall']:
            matches[relative] = digest((installed / relative).read_bytes()) == digest((source / relative).read_bytes())
        record['installed_files_match_build'] = matches
        assert all(matches.values()), 'An installed component differs from the tested build.'
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
        registrar = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
        if plan.get('source_app'):
            subprocess.run([registrar, '-f', str(installed)], check=True)
            previews = [source] + [Path(path) for path in plan.get('preview_app_paths', [])]
            for preview in previews:
                assert preview.is_relative_to(root/'build') and preview.name == 'HoRNDISStatus.app'
                subprocess.run([registrar, '-u', str(preview)], check=False)
        restore_integration_preferences()
        installed_receipt = json.loads((Path(caskroom)/'.metadata/INSTALL_RECEIPT.json').read_text())
        record['replacement_aware_cask_installed'] = any(
            directive.get('script', {}).get('args') == ['--homebrew']
            for artifact in installed_receipt.get('uninstall_artifacts', [])
            for directive in artifact.get('uninstall', []))
        assert record['replacement_aware_cask_installed'], 'Homebrew did not retain replacement-aware cleanup.'
        network_after = network_snapshot()
        record['network_service_before'] = network_before
        record['network_service_after'] = network_after
        record['network_service_preserved'] = network_before == network_after
        if plan.get('repair_fresh_defaults'):
            stable = ['service_ids', 'owned_bridge_options', 'orders']
            record['network_service_preserved'] = all(network_before[key] == network_after[key] for key in stable)
            preferences = plistlib.loads(Path('/Library/Preferences/SystemConfiguration/preferences.plist').read_bytes())
            for sid in network_after['service_ids']:
                config = preferences['NetworkServices'][sid]
                assert config.get('UserDefinedName') == 'HoRNDIS USB', '服务名称未修复。'
                assert config.get('IPv4', {}).get('ConfigMethod') == 'DHCP' and not config.get('IPv4', {}).get('__INACTIVE__'), 'DHCP 未启用。'
                assert sid not in config, '服务配置中仍有错误嵌套记录。'
            record['fresh_defaults_repaired'] = True
        if network_before['service_ids'] and not record['network_service_preserved']:
            raise RuntimeError('安装后网络服务标识、配置或排序发生变化，请检查安装记录。')
        record['surge_files_unchanged'] = all(snapshot(path) == before[str(path)] for path in protected)
        print('Homebrew 安装完成，已核对新应用和 Surge 联动组件。', flush=True)
except KeyboardInterrupt:
    exit_code = 130
    record['error'] = 'Interrupted'
except Exception as error:
    exit_code = 1
    record['error'] = str(error)
    print('安装未完成：' + str(error), file=sys.stderr, flush=True)
finally:
    if migration is not None:
        try:
            record['legacy_cask_metadata_restored'] = migration.restore_if_unused()
        except Exception as cleanup_error:
            record['metadata_restore_error'] = str(cleanup_error)
            exit_code = 1
    if recipe.read_bytes() == local:
        if not prepare and exit_code == 0 and plan.get('retain_cask_on_success'):
            # Keep the matching recipe after this migration, so a later plain
            # `brew reinstall` cannot fetch the older, incompatible package.
            record['matching_cask_retained'] = True
            record['cask_restored'] = False
        else:
            recipe.write_bytes(recipe_baseline)
            os.utime(recipe, ns=(recipe_stat.st_atime_ns, recipe_stat.st_mtime_ns))
            record['cask_restored'] = recipe.read_bytes() == recipe_baseline
    else:
        record['cask_restored'] = recipe.read_bytes() == recipe_baseline
        if not record['cask_restored']:
            print('cask 发生了并发修改，请保留备份并检查。', file=sys.stderr, flush=True)
            exit_code = 1
    record['completed_at'] = time.time()
    record['exit_code'] = exit_code
    destination = build / ('homebrew-preflight-result.json' if prepare else 'homebrew-install-result.json')
    destination.write_text(json.dumps(record, indent=2))
sys.exit(exit_code)
