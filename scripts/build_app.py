#!/usr/bin/env python3
"""Build a self-contained, universal macOS application and release ZIP."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default=(ROOT / 'VERSION').read_text().strip())
    parser.add_argument('--arch', choices=['universal', 'arm64', 'x86_64'], default='universal')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='floating-todo-build-') as temporary:
        stage = Path(temporary)
        app = stage / 'Floating Todo.app'
        macos = app / 'Contents/MacOS'
        resources = app / 'Contents/Resources'
        macos.mkdir(parents=True)
        resources.mkdir()
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(stage / 'module-cache'))
        architectures = ['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch]
        binaries = []
        sources = sorted((ROOT / 'Sources').glob('*.swift'))
        for architecture in architectures:
            binary = stage / ('FloatingTodo-' + architecture)
            run('xcrun', 'swiftc', '-O', '-target', architecture + '-apple-macosx13.0',
                *sources, '-framework', 'Cocoa', '-o', binary, env=env)
            binaries.append(binary)
        executable = macos / 'FloatingTodo'
        if len(binaries) > 1:
            run('xcrun', 'lipo', '-create', *binaries, '-output', executable)
        else:
            shutil.copyfile(binaries[0], executable)
        executable.chmod(0o755)
        info = dict(CFBundleName='Floating Todo', CFBundleDisplayName='Floating Todo',
                    CFBundleIdentifier='io.github.floating-todo.macos', CFBundleVersion=args.version,
                    CFBundleShortVersionString=args.version, CFBundleExecutable='FloatingTodo',
                    CFBundlePackageType='APPL', LSUIElement=True, NSHighResolutionCapable=True,
                    LSMinimumSystemVersion='13.0', CFBundleIconFile='AppIcon',
                    NSHumanReadableCopyright='Copyright © 2026 Floating Todo contributors. MIT License.')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copyfile(ROOT / 'scripts/todo_cli.py', resources / 'todo_cli.py')
        shutil.copyfile(ROOT / 'LICENSE', resources / 'LICENSE')
        icon_tool = stage / 'make-icon'
        run('xcrun', 'swiftc', '-target', 'arm64-apple-macosx13.0' if os.uname().machine == 'arm64' else 'x86_64-apple-macosx13.0',
            ROOT / 'scripts/make_icon.swift', '-o', icon_tool, env=env)
        iconset = stage / 'AppIcon.iconset'
        run(icon_tool, iconset)
        chunks = []
        for code, filename in [('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
                               ('icp6', 'icon_32x32@2x.png'), ('ic07', 'icon_128x128.png'),
                               ('ic08', 'icon_256x256.png'), ('ic09', 'icon_512x512.png'),
                               ('ic10', 'icon_512x512@2x.png')]:
            png = (iconset / filename).read_bytes()
            chunks.append(code.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
        body = b''.join(chunks)
        (resources / 'AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
        run('codesign', '--force', '--deep', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        run('xcrun', 'lipo', '-archs', executable)
        run(executable, '--layout-check')
        archive = args.output / f'FloatingTodo-{args.version}-macOS-{args.arch}.zip'
        if archive.exists():
            archive.unlink()
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', app, archive)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        (args.output / (archive.name + '.sha256')).write_text(checksum + '  ' + archive.name + '\n')
        # The ZIP is created from clean staging before iCloud/Finder metadata.
        destination = args.output / app.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(app, destination, copy_function=shutil.copyfile)
        (destination / 'Contents/MacOS/FloatingTodo').chmod(0o755)
        print(f'Ready: {archive}')

if __name__ == '__main__':
    main()
