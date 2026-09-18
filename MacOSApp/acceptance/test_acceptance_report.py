import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).resolve().parents[1] / "scripts/acceptance_report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class AcceptanceReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.log = self.root / "run.log"
        self.xml = self.root / "run.xml"
        self.contract = self.root / "required.json"
        self.contract.write_text(json.dumps({
            "version": 2,
            "requiredCheck": "acceptance-gate",
            "source": ["Core.testRequired"],
            "auth": ["Auth.testCallback"],
            "packaged": ["Widget.testClick"],
        }))

    def tearDown(self):
        self.temp.cleanup()

    def parse(self, log):
        self.log.write_text(log)
        report.convert(self.log, self.xml)

    def check(self, phase="source"):
        report.validate(self.xml, self.contract, phase)

    def test_known_passes_are_accepted(self):
        self.parse("Test Case '-[CoreTests.Core testRequired]' passed (0.001 seconds).\n")
        self.check()

    def test_unrelated_pass_does_not_satisfy_contract(self):
        self.parse("Test Case '-[Core testUnrelated]' passed (0.001 seconds).\n")
        with self.assertRaisesRegex(ValueError, "missing required"):
            self.check()

    def test_skips_are_preserved_and_rejected(self):
        self.parse("Test Case '-[Core testRequired]' passed (0.001 seconds).\nTest Case '-[Auth testCallback]' skipped (0.001 seconds).\n")
        self.assertIn("<skipped", self.xml.read_text())
        with self.assertRaises(ValueError):
            self.check()

    def test_failure_is_not_erased_by_later_success(self):
        self.parse("Test Case '-[Core testRequired]' failed (0.001 seconds).\nTest Case '-[Core testRequired]' passed (0.001 seconds).\n")
        with self.assertRaises(ValueError):
            self.check()

    def test_auth_and_packaged_are_both_required(self):
        self.parse("Test Case '-[Widget testClick]' passed (0.001 seconds).\n")
        with self.assertRaisesRegex(ValueError, "Auth.testCallback"):
            self.check("packaged")

    def test_empty_log_fails(self):
        with self.assertRaises(ValueError):
            self.parse("no matching tests\n")

    def test_unfinished_test_fails(self):
        with self.assertRaises(ValueError):
            self.parse("Test Case '-[Core testRequired]' started.\nTest Case '-[Other testPassed]' passed (0.001 seconds).\n")

    def test_new_unrecognized_case_format_fails(self):
        with self.assertRaises(ValueError):
            self.parse("Test Case 'Core.testRequired' unknown-state.\n")

    def test_swift_dot_format_is_supported(self):
        self.parse("Test Case 'CoreTests.Core.testRequired' started.\nTest Case 'CoreTests.Core.testRequired' passed (0.001 seconds).\n")
        self.check()

    def test_missing_report_fails(self):
        with self.assertRaises(OSError):
            self.check()

    def test_class_only_contract_cannot_replace_a_scenario(self):
        contract = json.loads(self.contract.read_text())
        contract["source"] = ["Core"]
        self.contract.write_text(json.dumps(contract))
        self.parse("Test Case '-[Core testUnrelated]' passed (0.001 seconds).\n")
        with self.assertRaisesRegex(ValueError, "exact XCTest methods"):
            self.check()

    def test_missing_contract_version_fails(self):
        contract = json.loads(self.contract.read_text())
        del contract["version"]
        self.contract.write_text(json.dumps(contract))
        self.parse("Test Case '-[Core testRequired]' passed (0.001 seconds).\n")
        with self.assertRaisesRegex(ValueError, "contract version"):
            self.check()

    def test_suite_error_without_failed_case_is_rejected(self):
        self.xml.write_text('<testsuite errors="1"><testcase classname="Core" name="testRequired"/></testsuite>')
        with self.assertRaisesRegex(ValueError, "suite errors"):
            self.check()


if __name__ == "__main__":
    unittest.main()
