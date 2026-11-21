from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SaverChargeEstimateTest(unittest.TestCase):
    def test_battery_metrics_and_target_estimate(self):
        with tempfile.TemporaryDirectory(prefix="cl-saver-estimate-") as directory:
            binary = Path(directory) / "saver_charge_estimate"
            source_dir = ROOT / "TweakChargingSaver"
            build = subprocess.run(
                ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                 "-framework", "Foundation", "-I", str(source_dir), "-o", str(binary),
                 str(source_dir / "CLSaverBattery.m"), str(ROOT / "tests/saver_charge_estimate.m")],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
