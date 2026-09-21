#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='floating-todo-check-') as d:
    executable = Path(d) / 'store-tests'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(d) / 'module-cache'))
    subprocess.run(['xcrun', 'swiftc', '-target', os.uname().machine + '-apple-macosx13.0', str(ROOT / 'Sources/Storage.swift'), str(ROOT / 'Tests/StoreTests.swift'), '-o', str(executable)], check=True, env=env)
    subprocess.run([str(executable)], check=True)
    resize = Path(d) / 'resize-tests'
    subprocess.run(['xcrun', 'swiftc', '-target', os.uname().machine + '-apple-macosx13.0', str(ROOT / 'Sources/ResizeGeometry.swift'), str(ROOT / 'Tests/ResizeTests.swift'), '-o', str(resize)], check=True, env=env)
    subprocess.run([str(resize)], check=True)
subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', str(ROOT / 'Tests'), '-p', 'test_*.py'], check=True)
