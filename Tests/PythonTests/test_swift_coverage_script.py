"""Exercise coverage discovery across SwiftPM's native and Xcode layouts."""

import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/check-swift-coverage.sh"


class SwiftCoverageScriptTests(unittest.TestCase):
    def run_gate(self, bundle_names, coverage="86.0", plist_mode="declared"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "products with spaces"
            (products / "codecov").mkdir(parents=True)
            (products / "codecov/default.profdata").touch()
            binaries = []
            for bundle_name, executable in bundle_names:
                contents = products / f"{bundle_name}.xctest/Contents"
                (contents / "MacOS").mkdir(parents=True)
                if plist_mode != "missing":
                    metadata = {"CFBundleExecutable": executable} if plist_mode == "declared" else {}
                    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
                binary = contents / "MacOS" / executable
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
                (contents / "MacOS" / f"{executable}.dSYM").mkdir()
                binaries.append(str(binary))

            commands = root / "commands"
            commands.mkdir()
            swift = commands / "swift"
            swift.write_text('#!/bin/sh\nif [ "$1" = build ]; then printf "%s\\n" "$TEST_PRODUCTS"; fi\n')
            swift.chmod(0o755)
            xcrun = commands / "xcrun"
            xcrun.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "open(os.environ['TEST_COV_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n"
                "print('TOTAL 100 10 90.0% 20 2 90.0% 100 14 ' + os.environ['TEST_COVERAGE'] + '%')\n"
            )
            xcrun.chmod(0o755)
            arguments = root / "arguments.json"
            env = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin", TEST_PRODUCTS=str(products),
                       TEST_COV_ARGS=str(arguments), TEST_COVERAGE=coverage, MLXTRA_CORE_COVERAGE_MIN="80")
            result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
            args = json.loads(arguments.read_text()) if arguments.exists() else []
            return result, args, binaries

    def test_native_and_xcode_bundle_names(self):
        for bundle, executable in (("MLXtraPackageTests", "MLXtraPackageTests"),
                                   ("MLXtraTests", "test-runner")):
            with self.subTest(bundle=bundle):
                result, args, binaries = self.run_gate([(bundle, executable)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(args[2], binaries[0])
                self.assertIn("meets required", result.stdout)

    def test_multiple_test_targets_are_included(self):
        result, args, binaries = self.run_gate([("CoreTests", "core"), ("OtherTests", "other")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[2:5], [binaries[0], "-object", binaries[1]])

    def test_native_bundles_without_executable_metadata(self):
        for plist_mode in ("missing", "empty"):
            with self.subTest(plist_mode=plist_mode):
                result, args, binaries = self.run_gate([("MLXtraPackageTests", "MLXtraPackageTests")],
                                                       plist_mode=plist_mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(args[2], binaries[0])
                self.assertNotIn("-object", args)

    def test_missing_bundle_fails_before_report(self):
        result, args, _ = self.run_gate([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Swift test binaries not found", result.stderr)
        self.assertEqual(args, [])

    def test_coverage_threshold_is_still_enforced(self):
        result, _, _ = self.run_gate([("MLXtraTests", "MLXtraTests")], coverage="79.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("below required", result.stderr)


if __name__ == "__main__":
    unittest.main()
