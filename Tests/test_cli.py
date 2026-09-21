import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('todo_cli', Path(__file__).resolve().parents[1] / 'scripts/todo_cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

class AddTaskTests(unittest.TestCase):
    def test_append_retry_and_preserve(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'tasks.json'
            state.write_text(json.dumps(dict(date='2026-01-01', tasks=[dict(id='old', title='Old', detail='', done=True)], opacity=0.8, reminderShown=True)))
            payload = dict(id='new', title='New', detail='More', date='2026-01-01')
            self.assertTrue(cli.add_task(state, payload)['created'])
            self.assertFalse(cli.add_task(state, payload)['created'])
            saved = json.loads(state.read_text())
            self.assertEqual(len(saved['tasks']), 2)
            self.assertTrue(saved['tasks'][0]['done'])
            self.assertTrue(saved['reminderShown'])
            before = state.read_bytes()
            for invalid in [dict(title=' '), dict(title='Wrong date', date='2026-01-02'), dict(id='new', title='Conflict')]:
                with self.assertRaises(ValueError):
                    cli.add_task(state, invalid)
                self.assertEqual(state.read_bytes(), before)

if __name__ == '__main__':
    unittest.main()
