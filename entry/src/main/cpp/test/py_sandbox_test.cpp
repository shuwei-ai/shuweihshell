/*
 * Host-side unit tests for MicroPython sandbox (py_sandbox).
 *
 * Runs on host via clang++:
 *   clang++ -std=c++17 -I entry/src/main/cpp -I entry/src/main/cpp/vendor/micropython/include \
 *       entry/src/main/cpp/py_sandbox.cpp entry/src/main/cpp/test/py_sandbox_test.cpp \
 *       entry/src/main/cpp/libs/host/libmicropython.a -o /tmp/py_sandbox_test && /tmp/py_sandbox_test
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "py_sandbox.h"

#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

int gFailures = 0;

void Check(bool condition, const char *what)
{
    if (!condition) {
        printf("FAIL %s\n", what);
        gFailures++;
    } else {
        printf("PASS %s\n", what);
    }
}

void TestBasicExecution()
{
    printf("\n--- TestBasicExecution ---\n");
    swshell::PySandboxOptions opts;
    auto res = swshell::ExecutePythonSandbox("print('hello', 'python', 10 + 32)", opts);
    Check(res.ok, "Basic script executes successfully");
    Check(!res.timedOut, "Basic script did not time out");
    Check(res.stdoutStr.find("hello python 42") != std::string::npos, "Captured stdout matches print output");
    Check(res.stderrStr.empty(), "Stderr is empty on success");
}

void TestJsonInputInjection()
{
    printf("\n--- TestJsonInputInjection ---\n");
    swshell::PySandboxOptions opts;
    opts.inputJson = "{\"title\": \"shuweihshell\", \"count\": 7, \"active\": true}";
    const char *code =
        "print('TITLE:', __input__['title'])\n"
        "print('COUNT_X2:', __input__['count'] * 2)\n"
        "print('ACTIVE:', __input__['active'])\n";
    auto res = swshell::ExecutePythonSandbox(code, opts);
    Check(res.ok, "JSON injection execution succeeds");
    Check(res.stdoutStr.find("TITLE: shuweihshell") != std::string::npos, "JSON property string matches");
    Check(res.stdoutStr.find("COUNT_X2: 14") != std::string::npos, "JSON number calculation matches");
    Check(res.stdoutStr.find("ACTIVE: True") != std::string::npos, "JSON boolean matches");
}

void TestBuiltinModules()
{
    printf("\n--- TestBuiltinModules ---\n");
    swshell::PySandboxOptions opts;
    const char *code =
        "import math\n"
        "import re\n"
        "import json\n"
        "import sys\n"
        "assert math.sqrt(25.0) == 5.0\n"
        "m = re.search(r'([a-z]+)=([0-9]+)', 'port=8710')\n"
        "assert m.group(1) == 'port' and m.group(2) == '8710'\n"
        "dumped = json.dumps({'code': 200, 'msg': 'ok'})\n"
        "assert 'code' in dumped\n"
        "print(sys.platform, 'MODULES_OK')\n";
    auto res = swshell::ExecutePythonSandbox(code, opts);
    Check(res.ok, "math/re/json/sys modules execute successfully");
    Check(res.stdoutStr.find("harmonyos MODULES_OK") != std::string::npos, "Platform and output confirmed");
}

void TestSyntaxError()
{
    printf("\n--- TestSyntaxError ---\n");
    swshell::PySandboxOptions opts;
    auto res = swshell::ExecutePythonSandbox("def broken_syntax(:", opts);
    Check(!res.ok, "Syntax error marks ok as false");
    Check(res.stderrStr.find("SyntaxError") != std::string::npos, "SyntaxError reported in stderr");
}

void TestRuntimeError()
{
    printf("\n--- TestRuntimeError ---\n");
    swshell::PySandboxOptions opts;
    auto res = swshell::ExecutePythonSandbox("1 // 0", opts);
    Check(!res.ok, "Division by zero marks ok as false");
    Check(res.stderrStr.find("ZeroDivisionError") != std::string::npos, "ZeroDivisionError reported in stderr");
}

void TestMemoryLimit()
{
    printf("\n--- TestMemoryLimit ---\n");
    swshell::PySandboxOptions opts;
    opts.heapLimitBytes = 64 * 1024; // 64 KB small heap
    auto res = swshell::ExecutePythonSandbox("huge = [i for i in range(100000)]", opts);
    Check(!res.ok, "Exceeding heap quota marks ok as false");
    Check(res.stderrStr.find("MemoryError") != std::string::npos, "MemoryError caught gracefully without crash");

    // Verify subsequent execution in fresh heap works normally
    opts.heapLimitBytes = 4 * 1024 * 1024;
    auto res2 = swshell::ExecutePythonSandbox("print('RECOVERED')", opts);
    Check(res2.ok, "Subsequent execution after MemoryError recovers cleanly");
    Check(res2.stdoutStr.find("RECOVERED") != std::string::npos, "Fresh heap allocated");
}

void TestTimeoutInterrupt()
{
    printf("\n--- TestTimeoutInterrupt ---\n");
    swshell::PySandboxOptions opts;
    opts.timeoutMs = 300; // 300 ms timeout
    auto res = swshell::ExecutePythonSandbox("while True:\n    pass\n", opts);
    Check(!res.ok, "Infinite loop marks ok as false");
    Check(res.timedOut, "Infinite loop flagged as timedOut");
    Check(res.stderrStr.find("timed out after 300ms") != std::string::npos, "Timeout message in stderr");
    Check(res.elapsedMs >= 250 && res.elapsedMs <= 1500, "Execution duration bounded by watchdog");
}

void TestDisabledFilesystem()
{
    printf("\n--- TestDisabledFilesystem ---\n");
    swshell::PySandboxOptions opts;
    auto res = swshell::ExecutePythonSandbox("open('/tmp/test.txt', 'w')", opts);
    Check(!res.ok, "open() call is blocked");
    Check(res.stderrStr.find("open() is disabled in sandbox") != std::string::npos, "Sandbox restriction reported");
}

} // namespace

int main()
{
    TestBasicExecution();
    TestJsonInputInjection();
    TestBuiltinModules();
    TestSyntaxError();
    TestRuntimeError();
    TestMemoryLimit();
    TestTimeoutInterrupt();
    TestDisabledFilesystem();

    printf("\n========================================\n");
    if (gFailures == 0) {
        printf("ALL PYTHON SANDBOX TESTS PASSED!\n");
        return 0;
    } else {
        printf("%d PYTHON SANDBOX TESTS FAILED!\n", gFailures);
        return 1;
    }
}
