import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "configure-signing.sh"
SECRET_NAMES = ["MACOS_CERTIFICATE_BASE64", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY",
                "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"]


class SigningConfigurationTests(unittest.TestCase):
    def test_no_credentials_selects_ad_hoc_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
            env["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run([str(SCRIPT)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "identity=-\nnotarize=false\n")

    def test_partial_credentials_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
            env.update({"GITHUB_OUTPUT": str(output), "MACOS_SIGNING_IDENTITY": "Developer ID Application: test"})
            result = subprocess.run([str(SCRIPT)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("partially configured", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
