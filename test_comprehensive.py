#!/usr/bin/env python3
"""
Comprehensive test suite for DPL compiler.
Tests all sample files and validates that they compile successfully.
"""

import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import List, Optional

@dataclass
class TestResult:
    name: str
    passed: bool
    error: Optional[str] = None


@dataclass
class Scenario:
    name: str
    code: str
    should_succeed: bool = True

class DPLCompilerTester:
    def __init__(self, compiler_path: str = "zig-out/bin/dpl-compiler"):
        self.compiler_path = compiler_path
        self.results: List[TestResult] = []

    def test_sample_files(self) -> None:
        """Test all sample DPL files."""
        samples_dir = Path("samples")
        if not samples_dir.exists():
            print(f"❌ Samples directory not found: {samples_dir}")
            return

        sample_files = sorted(samples_dir.glob("*.dpl"))
        print(f"\n{'='*60}")
        print(f"TESTING {len(sample_files)} SAMPLE FILES")
        print(f"{'='*60}\n")

        for sample_file in sample_files:
            self._test_sample(sample_file)

        self._print_results("Sample Files")

    def test_error_cases(self) -> None:
        """Test various error cases."""
        error_cases = [
            ("prime_outside_loop", "x = 5\nx' = 10"),
            ("undefined_variable", "x = undefined_var + 5"),
            ("double_assignment", "x = 5\nx = 10"),
            ("missing_paren", "x = (5 + 3"),
            ("missing_brace", "while (x < 10) {\n    x' = x + 1"),
            ("prime_in_condition", "i = 0\nwhile (i < 5) {\n    if (i' > 0) {\n        x = 1\n    }\n}"),
        ]

        print(f"\n{'='*60}")
        print(f"TESTING {len(error_cases)} ERROR CASES")
        print(f"{'='*60}\n")

        for name, code in error_cases:
            self._test_error_case(name, code)

        self._print_results("Error Cases")

    def test_nested_loops(self) -> None:
        """Test nested loop scenarios."""
        nested_cases = [
            Scenario(
                "simple_nested",
                "i = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        j` = j + 1\n    }\n    i` = i + 1\n}",
            ),
            Scenario(
                "outer_primes_modified_by_inner",
                "a = 1\nb = 0\ni = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        b` = b + 1\n        j` = j + 1\n    }\n    a` = a + b\n    i` = i + 1\n}",
            ),
            Scenario(
                "three_levels_nested",
                "i = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        k = 0\n        while (k < 2) {\n            k` = k + 1\n        }\n        j` = j + 1\n    }\n    i` = i + 1\n}",
            ),
            Scenario(
                "multiple_primes_outer_inner",
                "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        x` = x + 1\n        j` = j + 1\n    }\n    x` = x * 2\n    i` = i + 1\n}",
                should_succeed=False,
            ),
        ]
        print(f"\n{'='*60}")
        print(f"TESTING {len(nested_cases)} NESTED LOOP SCENARIOS")
        print(f"{'='*60}\n")

        for scenario in nested_cases:
            self._test_nested_case(scenario.name, scenario.code, scenario.should_succeed)

        self._print_results("Nested Loops")

    def test_negative_numbers(self) -> None:
        """Test unary minus and binary subtraction in one runtime scenario."""
        code = (
            "a = 10\n"
            "b = -3\n"
            "c = a - b\n"
            "d = -a + 5\n"
            "e = 20 - -4\n"
            "f = c + d + e\n"
            "f\n"
        )
        expected_output = "Result: 32"

        print(f"\n{'='*60}")
        print("TESTING NEGATIVE NUMBER SCENARIO")
        print(f"{'='*60}\n")

        try:
            with open("/tmp/test_negative_numbers.dpl", "w") as f:
                f.write(code)

            asm_path = "/tmp/test_negative_numbers.s"
            bin_path = "/tmp/test_negative_numbers"

            compile_result = subprocess.run(
                [self.compiler_path, "/tmp/test_negative_numbers.dpl", "-o", asm_path],
                capture_output=True,
                timeout=5,
            )
            if compile_result.returncode != 0:
                err = compile_result.stderr.decode()
                print("✗ FAIL: negative_numbers (compile failed)")
                self.results.append(TestResult("negative_numbers", False, err))
                return

            link_result = subprocess.run(
                ["gcc", asm_path, "-o", bin_path, "-lm"],
                capture_output=True,
                timeout=5,
            )
            if link_result.returncode != 0:
                err = link_result.stderr.decode()
                print("✗ FAIL: negative_numbers (link failed)")
                self.results.append(TestResult("negative_numbers", False, err))
                return

            run_result = subprocess.run([bin_path], capture_output=True, timeout=5)
            actual_output = run_result.stdout.decode().strip()

            self._print_expected_vs_actual(expected_output, actual_output)

            if run_result.returncode == 0 and actual_output == expected_output:
                print("✓ PASS: negative_numbers")
                self.results.append(TestResult("negative_numbers", True))
            else:
                err = run_result.stderr.decode()
                if not err:
                    err = f"Expected '{expected_output}', got '{actual_output}'"
                print("✗ FAIL: negative_numbers")
                self.results.append(TestResult("negative_numbers", False, err))

        except subprocess.TimeoutExpired:
            print("✗ FAIL: negative_numbers (timeout)")
            self.results.append(TestResult("negative_numbers", False, "Timeout"))
        except Exception as e:
            print(f"✗ FAIL: negative_numbers ({str(e)})")
            self.results.append(TestResult("negative_numbers", False, str(e)))

        self._print_results("Negative Numbers")

    def _test_sample(self, sample_file: Path) -> None:
        """Test a single sample file."""
        try:
            output_file = f"/tmp/{sample_file.stem}.s"
            result = subprocess.run(
                [self.compiler_path, str(sample_file), "-o", output_file],
                capture_output=True,
                timeout=5
            )

            if result.returncode == 0:
                print(f"✓ PASS: {sample_file.name}")
                self.results.append(TestResult(sample_file.name, True))
            else:
                error = result.stderr.decode()
                print(f"✗ FAIL: {sample_file.name}")
                if error:
                    print(f"  Error: {error[:100]}")
                self.results.append(TestResult(sample_file.name, False, error))
        except subprocess.TimeoutExpired:
            print(f"✗ FAIL: {sample_file.name} (timeout)")
            self.results.append(TestResult(sample_file.name, False, "Timeout"))
        except Exception as e:
            print(f"✗ FAIL: {sample_file.name} ({str(e)})")
            self.results.append(TestResult(sample_file.name, False, str(e)))

    def _test_error_case(self, name: str, code: str) -> None:
        """Test that error case is properly rejected."""
        try:
            with open("/tmp/test_error.dpl", "w") as f:
                f.write(code)

            result = subprocess.run(
                [self.compiler_path, "/tmp/test_error.dpl", "-o", "/tmp/test_error.s"],
                capture_output=True,
                timeout=5
            )

            if result.returncode != 0:
                print(f"✓ PASS: {name} (correctly rejected)")
                self.results.append(TestResult(name, True))
            else:
                print(f"✗ FAIL: {name} (should have failed)")
                self.results.append(TestResult(name, False, "Should have failed"))
        except Exception as e:
            print(f"✗ FAIL: {name} ({str(e)})")
            self.results.append(TestResult(name, False, str(e)))

    def _test_nested_case(self, name: str, code: str, should_succeed: bool = True) -> None:
        """Test nested loop scenario."""
        try:
            with open("/tmp/test_nested.dpl", "w") as f:
                f.write(code)

            result = subprocess.run(
                [self.compiler_path, "/tmp/test_nested.dpl", "-o", "/tmp/test_nested.s"],
                capture_output=True,
                timeout=5
            )

            if result.returncode == 0 and should_succeed:
                print(f"✓ PASS: {name}")
                self.results.append(TestResult(name, True))
            elif result.returncode != 0 and not should_succeed:
                print(f"✓ PASS: {name} (correctly rejected)")
                self.results.append(TestResult(name, True))
            else:
                error = result.stderr.decode()
                print(f"✗ FAIL: {name}")
                if error:
                    print(f"  Error: {error[:100]}")
                self.results.append(TestResult(name, False, error))
        except Exception as e:
            print(f"✗ FAIL: {name} ({str(e)})")
            self.results.append(TestResult(name, False, str(e)))

    def _print_results(self, category: str) -> None:
        """Print test results for a category."""
        passed = sum(1 for r in self.results if r.passed)
        total = len(self.results)
        rate = (passed / total * 100) if total > 0 else 0
        print(f"\n{'─'*60}")
        print(f"{category}: {passed}/{total} passed ({rate:.1f}%)")
        print(f"{'─'*60}")

    def _print_expected_vs_actual(self, expected: str, actual: str) -> None:
        """Print expected and actual output for quick debugging."""
        print(f"Expected output: {expected}")
        print(f"Actual output:   {actual}")

def main():
    if not Path("zig-out/bin/dpl-compiler").exists():
        print("❌ Compiler not built. Run: zig build")
        sys.exit(1)

    tester = DPLCompilerTester()

    try:
        tester.test_sample_files()
        tester.test_error_cases()
        tester.test_nested_loops()
        tester.test_negative_numbers()

        # Final summary
        total_passed = sum(1 for r in tester.results if r.passed)
        total_tests = len(tester.results)
        print(f"\n{'='*60}")
        print("FINAL RESULTS")
        print(f"{'='*60}")
        print(f"Total: {total_passed}/{total_tests} passed")
        print(f"Pass Rate: {total_passed/total_tests*100:.1f}%\n")

        sys.exit(0 if total_passed == total_tests else 1)

    except KeyboardInterrupt:
        print("\n\nTest suite interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n\nError running tests: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
