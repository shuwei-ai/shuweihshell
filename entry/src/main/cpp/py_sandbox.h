/*
 * Native offline Python execution sandbox backed by MicroPython Embed port.
 * Provides an isolated GC heap per evaluation with captured stdout/stderr,
 * JSON input injection (__input__), timeout interruption via watchdog thread,
 * and structured error reporting.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_PY_SANDBOX_H
#define SW_SHELL_PY_SANDBOX_H

#include <cstddef>
#include <cstdint>
#include <string>

namespace swshell {

struct PySandboxOptions {
    size_t heapLimitBytes = 4 * 1024 * 1024; // 4MB default GC heap
    uint32_t timeoutMs = 5000;              // 5s default execution budget
    std::string inputJson;                  // Bound to global `__input__` via json.loads
};

struct PySandboxResult {
    bool ok = false;
    bool timedOut = false;
    std::string stdoutStr;
    std::string stderrStr;
    int64_t elapsedMs = 0;
};

/**
 * Evaluates a Python script inside an isolated, memory-bounded MicroPython instance.
 *
 * @param code Python 3 source code to execute. Standard print() output is captured into stdoutStr.
 * @param options Execution budget, memory limits, and input JSON.
 */
PySandboxResult ExecutePythonSandbox(const std::string &code,
                                     const PySandboxOptions &options = PySandboxOptions());

}  // namespace swshell

#endif /* SW_SHELL_PY_SANDBOX_H */
