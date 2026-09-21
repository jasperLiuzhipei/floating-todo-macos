"""Atomically add a user-specified task without replacing existing progress."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import tempfile
import uuid


def add_task(state_path, payload):
    title = payload.get('title', '').strip()
    detail = payload.get('detail', '').strip()
    if not title:
        raise ValueError('任务标题不能为空')
    task_id = payload.get('id') or uuid.uuid4().hex
    with (state_path.parent / '.todo.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_path.read_text(encoding='utf-8'))
        if payload.get('date') and payload['date'] != state['date']:
            raise ValueError('日期与当前清单不同；请先确认是否创建新一天的清单')
        existing = next((t for t in state['tasks'] if t['id'] == task_id), None)
        if existing:
            if existing['title'] != title or existing['detail'] != detail:
                raise ValueError('同一任务 ID 已存在且内容不同')
            return {'created': False, 'task': existing}
        task = dict(id=task_id, title=title, detail=detail, done=False)
        state['tasks'].append(task)
        descriptor, temporary = tempfile.mkstemp(prefix='.todo-', dir=state_path.parent)
        try:
            with os.fdopen(descriptor, 'w', encoding='utf-8') as out:
                json.dump(state, out, ensure_ascii=False, indent=2)
                out.flush()
                os.fsync(out.fileno())
            os.replace(temporary, state_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return {'created': True, 'date': state['date'], 'task': task}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['add'])
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--state', type=Path, default=Path.home() / 'Library/Application Support/FloatingTodo/tasks.json')
    args = parser.parse_args()
    result = add_task(args.state, json.loads(args.input.read_text(encoding='utf-8')))
    print(json.dumps(result, ensure_ascii=False))
