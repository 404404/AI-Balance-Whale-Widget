#!/usr/bin/env python3
"""Preserve XCTest skips and enforce the checked-in scenario contract."""
import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import json

OBJC = re.compile(r"Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|failed|skipped)(?: \(([0-9.]+) seconds\))?")
SWIFT = re.compile(r"Test Case '([^']+)\.([^'.]+)' (started|passed|failed|skipped)(?: \(([0-9.]+) seconds\))?")


def convert(log_path, xml_path):
    cases = []
    pending = set()
    for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
        match = OBJC.search(line) or SWIFT.search(line)
        if not match:
            if "Test Case '" in line:
                raise ValueError("unrecognized XCTest case line; update the parser, do not drop evidence")
            continue
        cls, method, status, duration = match.groups()
        key = (cls, method.removesuffix("()"))
        if status == "started":
            pending.add(key)
        else:
            pending.discard(key)
            cases.append((key, status, duration or "0"))
    suite = ET.Element("testsuite", {
        "name": "AI-Balance-Whale acceptance",
        "tests": str(len(cases)),
        "failures": str(sum(status == "failed" for _, status, _ in cases)),
        "skipped": str(sum(status == "skipped" for _, status, _ in cases)),
        "errors": str(len(pending)),
    })
    for (cls, method), status, duration in cases:
        case = ET.SubElement(suite, "testcase", {"classname": cls, "name": method, "time": duration})
        if status == "failed":
            ET.SubElement(case, "failure", {"message": "XCTest reported failure"})
        elif status == "skipped":
            ET.SubElement(case, "skipped", {"message": "XCTest reported skip; mandatory acceptance cannot skip"})
    ET.ElementTree(suite).write(xml_path, encoding="utf-8", xml_declaration=True)
    if not cases or pending:
        raise ValueError(f"no completed tests or unfinished tests: {sorted(pending)}")
    return len(cases)


def required_names(contract, phase):
    if contract.get("requiredCheck") != "acceptance-gate" or contract.get("version") != 2:
        raise ValueError("invalid required check or contract version; expected version 2")
    groups = ["source"] if phase == "source" else ["auth", "packaged"]
    required = set()
    for group in groups:
        names = contract.get(group)
        if not isinstance(names, list) or not names or not all(isinstance(n, str) and n.strip() for n in names):
            raise ValueError(f"missing or empty contract group: {group}")
        if not all(re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\.test\w+", n) for n in names):
            raise ValueError(f"contract group {group} must name exact XCTest methods, not classes")
        required.update(names)
    return required


def validate(xml_path, contract_path, phase):
    required = required_names(json.loads(Path(contract_path).read_text()), phase)
    root = ET.parse(xml_path).getroot()
    cases = list(root.iter("testcase"))
    failures = []
    if not cases:
        failures.append("zero executed tests")
    for suite in root.iter("testsuite"):
        for field in ("failures", "errors", "skipped", "disabled"):
            if float(suite.get(field, "0")) != 0:
                failures.append(f"suite {field}={suite.get(field)}")
    completed = set()
    for case in cases:
        cls = case.get("classname", "")
        method = case.get("name", "").removesuffix("()")
        if not cls or not method:
            failures.append("testcase missing classname/name")
        if any(case.find(t) is not None for t in ("failure", "error", "skipped")):
            failures.append(f"not passed: {cls}.{method}")
        else:
            short = cls.rsplit(".", 1)[-1]
            completed.update((f"{cls}.{method}", f"{short}.{method}"))
    missing = required - completed
    if missing:
        failures.append("missing required scenarios: " + ", ".join(sorted(missing)))
    if failures:
        raise ValueError("\n".join(failures))
    print(f"PASS {phase}: {len(cases)} testcase results, {len(required)} required contracts")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("convert", "check"))
    parser.add_argument("--log")
    parser.add_argument("--xml", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--phase", choices=("source", "packaged"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "convert":
            if not args.log:
                raise ValueError("convert requires --log")
            convert(args.log, args.xml)
        validate(args.xml, args.contract, args.phase)
    except (ValueError, OSError, ET.ParseError) as error:
        print(f"ACCEPTANCE FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
