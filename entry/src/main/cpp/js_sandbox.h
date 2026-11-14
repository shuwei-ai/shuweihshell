/*
 * Native offline JavaScript execution sandbox backed by HarmonyOS libjsvm.so (V8/JSVM).
 * Provides an isolated VM/Env per evaluation with captured console output, JSON input injection,
 * memory bounds, and structured error reporting.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_JS_SANDBOX_H
#define SW_SHELL_JS_SANDBOX_H

#include <cstdint>
#include <string>

namespace swshell {

struct JsEvalResult {
    bool ok = false;
    std::string result;
    std::string logs;
    std::string error;
    int64_t elapsedMs = 0;
};

/**
 * Evaluates a JavaScript snippet inside a fresh, memory-bounded JSVM instance.
 *
 * @param code JavaScript source to execute. Supports both completion values and top-level `return`.
 * @param inputJson Optional JSON string parsed and bound to global `input`.
 * @param timeoutMs Soft execution budget annotation in milliseconds (clamped inside implementation).
 */
JsEvalResult EvalJsSandbox(const std::string &code,
                           const std::string &inputJson = std::string(),
                           int timeoutMs = 5000);

}  // namespace swshell

#endif /* SW_SHELL_JS_SANDBOX_H */
