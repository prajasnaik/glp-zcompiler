#!/usr/bin/env python3
"""
Test suite for string operations with prime operator and type mismatch errors.
Tests string manipulation in loops and runtime type errors.
"""

import subprocess
import sys
from pathlib import Path

class DPLStringAndTypeTester:
    def __init__(self, compiler_path: str = "zig-out/bin/dpl-compiler"):
        self.compiler_path = compiler_path
        self.results = {
            "passed": 0,
            "failed": 0,
            "errors": []
        }

    def run_all_tests(self) -> None:
        """Run all test categories."""
        print(f"\n{'='*70}")
        print("STRING OPERATIONS WITH PRIME OPERATOR & TYPE MISMATCH TESTS")
        print(f"{'='*70}\n")

        self.test_string_prime_in_loops()
        self.test_type_mismatch_errors()
        self.test_string_loop_concatenation()
        
        self._print_summary()

    def test_string_prime_in_loops(self) -> None:
        """Test string mutation using prime operator in loops."""
        print("─" * 70)
        print("STRING MUTATION IN LOOPS (Prime Operator)")
        print("─" * 70)

        test_cases = [
            {
                "name": "Simple string concatenation in loop",
                "code": '''result = ""
i = 0
while (i < 3) {
    result` = result + "x"
    i` = i + 1
}
result''',
                "should_succeed": True,
            },
            {
                "name": "String slicing in loop",
                "code": '''s = "abcdef"
out = ""
i = 0
while (i < 3) {
    out` = out + s[i:i+2]
    i` = i + 1
}
out''',
                "should_succeed": True,
            },
            {
                "name": "String indexing in loop",
                "code": '''s = "hello"
out = ""
i = 0
while (i < 5) {
    out` = out + s[i]
    i` = i + 1
}
out''',
                "should_succeed": True,
            },
            {
                "name": "Nested loop with string concatenation",
                "code": '''result = ""
i = 0
while (i < 2) {
    j = 0
    while (j < 3) {
        result` = result + "a"
        j` = j + 1
    }
    i` = i + 1
}
result''',
                "should_succeed": True,
            },
            {
                "name": "String with find() in loop",
                "code": '''haystack = "the quick brown fox"
needle = "o"
count = 0
pos = 0
while (pos < 20) {
    idx = find(haystack[pos:], needle)
    if (idx >= 0) {
        count` = count + 1
        pos` = pos + idx + 1
    }
}
count''',
                "should_succeed": True,
            },
            {
                "name": "String building with print in loop",
                "code": '''word = "test"
i = 0
while (i < 2) {
    print("Iteration {} - word: {}", i, word)
    i` = i + 1
}
word''',
                "should_succeed": True,
            },
        ]

        for test in test_cases:
            self._test_compile(test["name"], test["code"], test["should_succeed"])

    def test_type_mismatch_errors(self) -> None:
        """Test type mismatch errors that should fail at compile or runtime."""
        print("\n" + "─" * 70)
        print("TYPE MISMATCH ERRORS")
        print("─" * 70)

        test_cases = [
            {
                "name": "String + integer",
                "code": 's = "hello"\nx = 5\nresult = s + x',
                "should_succeed": False,
            },
            {
                "name": "Integer + string",
                "code": 'x = 5\ns = "hello"\nresult = x + s',
                "should_succeed": False,
            },
            {
                "name": "String - integer",
                "code": 's = "hello"\nx = 5\nresult = s - x',
                "should_succeed": False,
            },
            {
                "name": "String * integer",
                "code": 's = "hello"\nx = 5\nresult = s * x',
                "should_succeed": False,
            },
            {
                "name": "String / integer",
                "code": 's = "hello"\nx = 5\nresult = s / x',
                "should_succeed": False,
            },
            {
                "name": "String ^ (power) integer",
                "code": 's = "hello"\nx = 5\nresult = s ^ x',
                "should_succeed": False,
            },
            {
                "name": "Float + string",
                "code": 'x = 3.14\ns = "hello"\nresult = x + s',
                "should_succeed": False,
            },
            {
                "name": "String + float",
                "code": 's = "hello"\nx = 3.14\nresult = s + x',
                "should_succeed": False,
            },
            {
                "name": "Boolean + string",
                "code": 'b = true\ns = "hello"\nresult = b + s',
                "should_succeed": False,
            },
            {
                "name": "String + boolean",
                "code": 's = "hello"\nb = true\nresult = s + b',
                "should_succeed": False,
            },
            {
                "name": "String comparison with int",
                "code": 's = "hello"\nx = 5\nresult = s > x',
                "should_succeed": False,
            },
            {
                "name": "String equality with int",
                "code": 's = "hello"\nx = 5\nresult = s == x',
                "should_succeed": False,
            },
            {
                "name": "String in while condition comparing to int",
                "code": 's = "hello"\nwhile (s < 10) {\n    x = 1\n}',
                "should_succeed": False,
            },
            {
                "name": "Integer index on string (correct)",
                "code": 's = "hello"\nx = s[0]\nx',
                "should_succeed": True,
            },
            {
                "name": "String index on string (wrong)",
                "code": 's = "hello"\nidx = "0"\nx = s[idx]',
                "should_succeed": False,
            },
            {
                "name": "Float index on string (wrong)",
                "code": 's = "hello"\nx = s[1.5]',
                "should_succeed": False,
            },
        ]

        for test in test_cases:
            self._test_compile(test["name"], test["code"], test["should_succeed"])

    def test_string_loop_concatenation(self) -> None:
        """Test various string concatenation patterns in loops."""
        print("\n" + "─" * 70)
        print("ADVANCED STRING LOOP PATTERNS")
        print("─" * 70)

        test_cases = [
            {
                "name": "CSV-like string building",
                "code": '''csv = ""
i = 0
while (i < 3) {
    if (i > 0) {
        csv` = csv + ","
    }
    csv` = csv + "item"
    i` = i + 1
}
csv''',
                "should_succeed": False,
            },
            {
                "name": "String repeat with loop",
                "code": '''pattern = "ab"
result = ""
i = 0
while (i < 4) {
    result` = result + pattern
    i` = i + 1
}
result''',
                "should_succeed": True,
            },
            {
                "name": "String reversal with loop",
                "code": '''s = "hello"
rev = ""
i = 4
while (i >= 0) {
    rev` = rev + s[i]
    i` = i - 1
}
rev''',
                "should_succeed": True,
            },
            {
                "name": "String with find and extract",
                "code": '''text = "apple banana cherry"
result = ""
sep = " "
i = 0
while (i < 3) {
    idx = find(text, sep)
    if (idx >= 0) {
        result` = result + text[0:idx]
        text` = text[idx+1:]
    }
    i` = i + 1
}
result''',
                "should_succeed": True,
            },
            {
                "name": "Multiple string variables in loop",
                "code": '''a = "x"
b = "y"
c = ""
i = 0
while (i < 2) {
    c` = c + a
    c` = c + b
    i` = i + 1
}
c''',
                "should_succeed": False,  # Can't assign to c twice in one loop
            },
            {
                "name": "String building with conditional",
                "code": '''result = ""
i = 0
while (i < 5) {
    if (i < 3) {
        result` = result + "e"
    } else {
        result` = result + "o"
    }
    i` = i + 1
}
result''',
                "should_succeed": True,
            },
        ]

        for test in test_cases:
            self._test_compile(test["name"], test["code"], test["should_succeed"])

    def _test_compile(self, name: str, code: str, should_succeed: bool) -> None:
        """Test if code compiles as expected."""
        try:
            # Write code to temp file
            temp_file = Path("/tmp/test_dpl_temp.dpl")
            temp_file.write_text(code)
            
            # Try to compile
            result = subprocess.run(
                [self.compiler_path, str(temp_file), "-o", "/tmp/test_dpl_out.s"],
                capture_output=True,
                timeout=5
            )
            
            success = result.returncode == 0
            
            if success == should_succeed:
                status = "✓ PASS"
                self.results["passed"] += 1
            else:
                status = "✗ FAIL"
                self.results["failed"] += 1
                self.results["errors"].append({
                    "test": name,
                    "expected": "success" if should_succeed else "failure",
                    "got": "success" if success else "failure",
                    "stderr": result.stderr.decode()[:200] if result.stderr else ""
                })
            
            print(f"{status}: {name}")
            
        except subprocess.TimeoutExpired:
            print(f"✗ FAIL: {name} (timeout)")
            self.results["failed"] += 1
            self.results["errors"].append({"test": name, "error": "timeout"})
        except Exception as e:
            print(f"✗ FAIL: {name} (exception: {e})")
            self.results["failed"] += 1
            self.results["errors"].append({"test": name, "error": str(e)})

    def _print_summary(self) -> None:
        """Print test summary."""
        total = self.results["passed"] + self.results["failed"]
        pass_rate = (self.results["passed"] / total * 100) if total > 0 else 0
        
        print("\n" + "=" * 70)
        print("TEST SUMMARY")
        print("=" * 70)
        print(f"Passed: {self.results['passed']}")
        print(f"Failed: {self.results['failed']}")
        print(f"Total:  {total}")
        print(f"Pass Rate: {pass_rate:.1f}%")
        
        if self.results["errors"]:
            print("\nFailed Tests Details:")
            for error in self.results["errors"]:
                print(f"  - {error['test']}")
                if "expected" in error:
                    print(f"    Expected: {error['expected']}, Got: {error['got']}")
                if error.get("stderr"):
                    print(f"    Error: {error['stderr']}")
        
        print()
        return 0 if self.results["failed"] == 0 else 1


if __name__ == "__main__":
    tester = DPLStringAndTypeTester()
    tester.run_all_tests()
    sys.exit(0 if tester.results["failed"] == 0 else 1)
