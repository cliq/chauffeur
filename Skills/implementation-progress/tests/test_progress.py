import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "progress.py"


class ProgressTests(unittest.TestCase):
    def test_updates_publish_versioned_json_and_matching_javascript(self):
        with tempfile.TemporaryDirectory() as directory:
            def run(*args):
                subprocess.run([sys.executable, str(SCRIPT), *args, "--dir", directory],
                               check=True, capture_output=True, text=True)

            def snapshot():
                root = Path(directory)
                data = json.loads((root / "progress.json").read_text())
                javascript = (root / "progress.js").read_text()
                self.assertEqual(json.loads(javascript[len("window.IMPLEMENTATION_PROGRESS = "):].strip()[:-1]), data)
                self.assertEqual(data.get("schemaVersion"), 1)
                return data

            run("init", "--title", "Fixture", "--phase", "Build", "--phase", "Check")
            original_html = (Path(directory) / "index.html").read_bytes()
            self.assertEqual(snapshot()["percentComplete"], 25)
            run("step", "1", "First", "done")
            run("step", "1", "Second", "blocked")
            run("phase", "1", "done")
            self.assertEqual(snapshot()["phases"][0]["steps"][1]["state"], "blocked")
            self.assertEqual(snapshot()["percentComplete"], 50)
            run("phase", "2", "active")
            self.assertEqual(snapshot()["percentComplete"], 75)
            run("phase", "2", "done")
            run("now", "Finished ✓")
            self.assertEqual(snapshot()["percentComplete"], 100)
            self.assertEqual(snapshot()["now"], "Finished ✓")
            self.assertEqual((Path(directory) / "index.html").read_bytes(), original_html)

    def test_legacy_json_is_upgraded_on_next_update(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "progress.json"
            path.write_text(json.dumps({"title": "Legacy", "phases": [], "now": "Before"}))
            subprocess.run([sys.executable, str(SCRIPT), "now", "--dir", directory, "After"], check=True)
            data = json.loads(path.read_text())
            self.assertEqual(data.get("schemaVersion"), 1)
            self.assertEqual(data["percentComplete"], 0)

    def test_percentage_rounds_halves_up_like_the_html(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, str(SCRIPT), "init", "--dir", directory,
                            "--title", "Rounding", "--phase", "One", "--phase", "Two",
                            "--phase", "Three", "--phase", "Four"], check=True, capture_output=True)
            self.assertEqual(json.loads((Path(directory) / "progress.json").read_text())["percentComplete"], 13)


if __name__ == "__main__":
    unittest.main()
