from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SAMPLES_DIR = ROOT / "samples"
OUT_DIR = ROOT / "outputs" / "sample_test_runs"
COMPILER = ROOT / "zig-out" / "bin" / "glp_zcompiler"

EXPECTED_OUTPUTS: dict[str, str] = {
    "01_int_arithmetic.dpl": "Result: 256",
    "02_float_arithmetic.dpl": "Result: 1.333333",
    "03_mixed_int_float.dpl": "Result: 6.000000",
    "04_comparisons.dpl": "Result: 1",
    "05_booleans.dpl": "Result: 1",
    "06_if_else.dpl": "Result: 0",
    "07_if_no_else.dpl": "Result: 0",
    "08_while_sum.dpl": "Result: 10",
    "09_fibonacci.dpl": "Result: 89",
    "10_precedence.dpl": "Result: 512",
    "11_nested_while.dpl": "Result: 9",
    "12_geometric_series.dpl": "Result: 80",
    "13_float_while.dpl": "Result: 3.500000",
    "14_combined_logic.dpl": "Result: 1",
    "15_function_add.dpl": "Result: 42",
    "16_recursive_function_fib.dpl": "Result: 55",
    "17_function_loop_prime_sum.dpl": "Result: 55",
    "18_function_loop_prime_fib.dpl": "Result: 55",
}


def ensure_tool(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Required tool not found on PATH: {name}")


def run(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, check=True, text=True, capture_output=True)


def build_compiler() -> None:
    ensure_tool("zig")
    ensure_tool("gcc")
    run(["zig", "build"], cwd=ROOT)
    if not COMPILER.exists():
        raise RuntimeError(f"Compiler binary not found after build: {COMPILER}")


def compile_and_run_sample(sample: Path) -> str:
    asm_path = OUT_DIR / f"{sample.stem}.s"
    exe_path = OUT_DIR / sample.stem

    run([str(COMPILER), str(sample), "-o", str(asm_path)], cwd=ROOT)
    run(["gcc", str(asm_path), "-o", str(exe_path), "-lm"], cwd=ROOT)
    completed = run([str(exe_path)], cwd=ROOT)
    return completed.stdout.strip()


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    build_compiler()

    sample_paths = sorted(SAMPLES_DIR.glob("*.dpl"))
    sample_names = {sample.name for sample in sample_paths}
    expected_names = set(EXPECTED_OUTPUTS)

    missing_expectations = sorted(sample_names - expected_names)
    stale_expectations = sorted(expected_names - sample_names)
    if missing_expectations or stale_expectations:
        if missing_expectations:
            print("Missing expected outputs for samples:", ", ".join(missing_expectations), file=sys.stderr)
        if stale_expectations:
            print("Expected outputs listed for missing samples:", ", ".join(stale_expectations), file=sys.stderr)
        return 1

    failures: list[str] = []
    for sample in sample_paths:
        actual = compile_and_run_sample(sample)
        expected = EXPECTED_OUTPUTS[sample.name]
        if actual != expected:
            failures.append(f"{sample.name}: expected {expected!r}, got {actual!r}")
        else:
            print(f"PASS {sample.name}: {actual}")

    if failures:
        print("\nSample regression failures:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"\nAll {len(sample_paths)} sample regressions passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())