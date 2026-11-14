/*
 * Native offline JavaScript sandbox implementation using HarmonyOS NDK JSVM (libjsvm.so).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "js_sandbox.h"

#include <ark_runtime/jsvm.h>

#include <algorithm>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

namespace swshell {

namespace {

constexpr size_t kMaxLogBytes = 128 * 1024;
constexpr size_t kMaxResultBytes = 128 * 1024;
constexpr size_t kMaxOldGenBytes = 64 * 1024 * 1024;
constexpr size_t kMaxYoungGenBytes = 16 * 1024 * 1024;

std::once_flag gJsvmInitOnce;
std::mutex gJsEvalMutex;

void EnsureJsvmInitialized()
{
    std::call_once(gJsvmInitOnce, []() {
        JSVM_InitOptions initOpts{};
        // Returns JSVM_GENERIC_FAILURE if already initialized in process, which is benign.
        (void)OH_JSVM_Init(&initOpts);
    });
}

std::string ReadUtf8String(JSVM_Env env, JSVM_Value strVal)
{
    size_t len = 0;
    if (OH_JSVM_GetValueStringUtf8(env, strVal, nullptr, 0, &len) != JSVM_OK) {
        return std::string();
    }
    if (len == 0) {
        return std::string();
    }
    std::string out(len + 1, '\0');
    size_t copied = 0;
    if (OH_JSVM_GetValueStringUtf8(env, strVal, &out[0], out.size(), &copied) != JSVM_OK) {
        return std::string();
    }
    out.resize(copied);
    return out;
}

std::string CoerceToUtf8(JSVM_Env env, JSVM_Value val)
{
    if (val == nullptr) {
        return "undefined";
    }
    JSVM_ValueType vtype = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, val, &vtype) != JSVM_OK) {
        return "<unknown>";
    }
    if (vtype == JSVM_UNDEFINED) {
        return "undefined";
    }
    if (vtype == JSVM_NULL) {
        return "null";
    }
    if (vtype == JSVM_STRING) {
        return ReadUtf8String(env, val);
    }
    JSVM_Value strVal = nullptr;
    if (OH_JSVM_CoerceToString(env, val, &strVal) != JSVM_OK || strVal == nullptr) {
        bool pending = false;
        if (OH_JSVM_IsExceptionPending(env, &pending) == JSVM_OK && pending) {
            JSVM_Value ignored = nullptr;
            OH_JSVM_GetAndClearLastException(env, &ignored);
        }
        return "[Unstringifiable value]";
    }
    return ReadUtf8String(env, strVal);
}

std::string FormatValueCompact(JSVM_Env env, JSVM_Value val, bool undefinedAsEmpty)
{
    if (val == nullptr) {
        return undefinedAsEmpty ? std::string() : "undefined";
    }
    JSVM_ValueType vtype = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, val, &vtype) != JSVM_OK) {
        return std::string();
    }
    if (vtype == JSVM_UNDEFINED) {
        return undefinedAsEmpty ? std::string() : "undefined";
    }
    if (vtype == JSVM_NULL) {
        return "null";
    }
    if (vtype == JSVM_STRING) {
        return ReadUtf8String(env, val);
    }
    if (vtype == JSVM_OBJECT) {
        JSVM_Value jsonStr = nullptr;
        JSVM_Status jStatus = OH_JSVM_JsonStringify(env, val, &jsonStr);
        if (jStatus == JSVM_OK && jsonStr != nullptr) {
            JSVM_ValueType jsonType = JSVM_UNDEFINED;
            if (OH_JSVM_Typeof(env, jsonStr, &jsonType) == JSVM_OK && jsonType == JSVM_STRING) {
                return ReadUtf8String(env, jsonStr);
            }
        }
        bool pending = false;
        if (OH_JSVM_IsExceptionPending(env, &pending) == JSVM_OK && pending) {
            JSVM_Value ignored = nullptr;
            OH_JSVM_GetAndClearLastException(env, &ignored);
        }
    }
    return CoerceToUtf8(env, val);
}

std::string ConsumeExceptionText(JSVM_Env env)
{
    bool pending = false;
    if (OH_JSVM_IsExceptionPending(env, &pending) != JSVM_OK || !pending) {
        return std::string();
    }
    JSVM_Value exc = nullptr;
    if (OH_JSVM_GetAndClearLastException(env, &exc) != JSVM_OK || exc == nullptr) {
        return "JavaScript exception occurred";
    }
    JSVM_ValueType vtype = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, exc, &vtype) == JSVM_OK && vtype == JSVM_OBJECT) {
        JSVM_Value stackVal = nullptr;
        if (OH_JSVM_GetNamedProperty(env, exc, "stack", &stackVal) == JSVM_OK && stackVal != nullptr) {
            JSVM_ValueType stype = JSVM_UNDEFINED;
            if (OH_JSVM_Typeof(env, stackVal, &stype) == JSVM_OK && stype == JSVM_STRING) {
                std::string stackStr = ReadUtf8String(env, stackVal);
                if (!stackStr.empty()) {
                    return stackStr;
                }
            }
        }
    }
    return CoerceToUtf8(env, exc);
}

struct LogState {
    std::string buffer;
    bool truncated = false;
};

struct ConsoleBinding {
    LogState *state = nullptr;
    const char *prefix = "";
};

JSVM_Value JSVM_CDECL ConsoleMethodCallback(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 16;
    JSVM_Value argv[16] = {nullptr};
    void *rawData = nullptr;
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &rawData);

    // Handle calls with >16 arguments gracefully
    std::vector<JSVM_Value> dynArgs;
    JSVM_Value *args = argv;
    if (argc > 16) {
        dynArgs.resize(argc, nullptr);
        OH_JSVM_GetCbInfo(env, info, &argc, dynArgs.data(), nullptr, &rawData);
        args = dynArgs.data();
    }

    auto *binding = static_cast<ConsoleBinding *>(rawData);
    if (binding != nullptr && binding->state != nullptr && !binding->state->truncated) {
        std::string line = binding->prefix ? binding->prefix : "";
        for (size_t i = 0; i < argc; ++i) {
            if (i > 0) {
                line.push_back(' ');
            }
            line.append(FormatValueCompact(env, args[i], false));
        }
        line.push_back('\n');

        LogState *st = binding->state;
        if (st->buffer.size() + line.size() <= kMaxLogBytes) {
            st->buffer.append(line);
        } else {
            size_t avail = kMaxLogBytes > st->buffer.size() ? kMaxLogBytes - st->buffer.size() : 0;
            if (avail > 0) {
                st->buffer.append(line.substr(0, avail));
            }
            st->buffer.append("\n...[console output truncated at 128 KB]");
            st->truncated = true;
        }
    }

    JSVM_Value undef = nullptr;
    OH_JSVM_GetUndefined(env, &undef);
    return undef;
}

class SandboxScopeGuard {
public:
    ~SandboxScopeGuard()
    {
        if (handleScope != nullptr && env != nullptr) {
            OH_JSVM_CloseHandleScope(env, handleScope);
        }
        if (envScope != nullptr && env != nullptr) {
            OH_JSVM_CloseEnvScope(env, envScope);
        }
        if (env != nullptr) {
            OH_JSVM_DestroyEnv(env);
        }
        if (vmScope != nullptr && vm != nullptr) {
            OH_JSVM_CloseVMScope(vm, vmScope);
        }
        if (vm != nullptr) {
            OH_JSVM_DestroyVM(vm);
        }
    }

    JSVM_VM vm = nullptr;
    JSVM_VMScope vmScope = nullptr;
    JSVM_Env env = nullptr;
    JSVM_EnvScope envScope = nullptr;
    JSVM_HandleScope handleScope = nullptr;
};

void RegisterConsoleBindings(JSVM_Env env, JSVM_Value global,
                             std::vector<JSVM_CallbackStruct> &cbStorage,
                             std::vector<ConsoleBinding> &bindings,
                             LogState *logState)
{
    struct Entry {
        const char *name;
        const char *prefix;
    };
    static const Entry kMethods[] = {
        { "log", "" },
        { "info", "" },
        { "warn", "[WARN] " },
        { "error", "[ERROR] " }
    };

    bindings.reserve(5);
    cbStorage.reserve(5);

    JSVM_Value consoleObj = nullptr;
    if (OH_JSVM_CreateObject(env, &consoleObj) != JSVM_OK || consoleObj == nullptr) {
        return;
    }

    for (const auto &entry : kMethods) {
        bindings.push_back(ConsoleBinding{logState, entry.prefix});
        cbStorage.push_back(JSVM_CallbackStruct{ConsoleMethodCallback, &bindings.back()});
        JSVM_Value fn = nullptr;
        if (OH_JSVM_CreateFunction(env, entry.name, JSVM_AUTO_LENGTH, &cbStorage.back(), &fn) == JSVM_OK &&
            fn != nullptr) {
            OH_JSVM_SetNamedProperty(env, consoleObj, entry.name, fn);
        }
    }
    OH_JSVM_SetNamedProperty(env, global, "console", consoleObj);

    // Expose print(...) as an alias of console.log
    bindings.push_back(ConsoleBinding{logState, ""});
    cbStorage.push_back(JSVM_CallbackStruct{ConsoleMethodCallback, &bindings.back()});
    JSVM_Value printFn = nullptr;
    if (OH_JSVM_CreateFunction(env, "print", JSVM_AUTO_LENGTH, &cbStorage.back(), &printFn) == JSVM_OK &&
        printFn != nullptr) {
        OH_JSVM_SetNamedProperty(env, global, "print", printFn);
    }
}

bool CompileWithOptionalReturnWrapper(JSVM_Env env, const std::string &code, JSVM_Script *outScript, std::string &outErr)
{
    auto tryCompile = [&](const std::string &src, std::string &errText) -> bool {
        JSVM_Value srcVal = nullptr;
        if (OH_JSVM_CreateStringUtf8(env, src.data(), src.size(), &srcVal) != JSVM_OK || srcVal == nullptr) {
            errText = "Failed to allocate script string in JSVM";
            return false;
        }
        JSVM_Status st = OH_JSVM_CompileScript(env, srcVal, nullptr, 0, false, nullptr, outScript);
        if (st == JSVM_OK && *outScript != nullptr) {
            return true;
        }
        errText = ConsumeExceptionText(env);
        if (errText.empty()) {
            errText = "SyntaxError: script compilation failed (status " + std::to_string(static_cast<int>(st)) + ")";
        }
        return false;
    };

    if (tryCompile(code, outErr)) {
        return true;
    }

    // If script used top-level `return`, retry inside an IIFE transparently
    if (outErr.find("return") != std::string::npos || outErr.find("Return") != std::string::npos) {
        std::string wrapped = "(function() {\n" + code + "\n})();";
        std::string secondErr;
        if (tryCompile(wrapped, secondErr)) {
            outErr.clear();
            return true;
        }
        outErr = secondErr;
    }
    return false;
}

}  // namespace

JsEvalResult EvalJsSandbox(const std::string &code, const std::string &inputJson, int timeoutMs)
{
    JsEvalResult out;
    if (code.empty()) {
        out.error = "JavaScript code cannot be empty";
        return out;
    }

    const int budgetMs = std::max(100, std::min(60000, timeoutMs));
    const auto startedAt = std::chrono::steady_clock::now();

    std::lock_guard<std::mutex> evalLock(gJsEvalMutex);
    EnsureJsvmInitialized();

    SandboxScopeGuard guard;
    JSVM_CreateVMOptions vmOpts{};
    vmOpts.maxOldGenerationSize = kMaxOldGenBytes;
    vmOpts.maxYoungGenerationSize = kMaxYoungGenBytes;

    if (OH_JSVM_CreateVM(&vmOpts, &guard.vm) != JSVM_OK || guard.vm == nullptr) {
        out.error = "Failed to initialize JSVM virtual machine";
        return out;
    }
    if (OH_JSVM_OpenVMScope(guard.vm, &guard.vmScope) != JSVM_OK) {
        out.error = "Failed to open JSVM VM scope";
        return out;
    }
    if (OH_JSVM_CreateEnv(guard.vm, 0, nullptr, &guard.env) != JSVM_OK || guard.env == nullptr) {
        out.error = "Failed to create JSVM execution environment";
        return out;
    }
    if (OH_JSVM_OpenEnvScope(guard.env, &guard.envScope) != JSVM_OK) {
        out.error = "Failed to open JSVM environment scope";
        return out;
    }
    if (OH_JSVM_OpenHandleScope(guard.env, &guard.handleScope) != JSVM_OK) {
        out.error = "Failed to open JSVM handle scope";
        return out;
    }

    JSVM_Value global = nullptr;
    if (OH_JSVM_GetGlobal(guard.env, &global) != JSVM_OK || global == nullptr) {
        out.error = "Failed to acquire global object";
        return out;
    }

    LogState logState;
    std::vector<JSVM_CallbackStruct> cbStorage;
    std::vector<ConsoleBinding> bindings;
    RegisterConsoleBindings(guard.env, global, cbStorage, bindings, &logState);

    // Inject parsed `input` JSON global if provided
    JSVM_Value inputVal = nullptr;
    if (!inputJson.empty()) {
        JSVM_Value rawInputStr = nullptr;
        if (OH_JSVM_CreateStringUtf8(guard.env, inputJson.data(), inputJson.size(), &rawInputStr) != JSVM_OK) {
            out.error = "Failed to allocate input_json string";
            return out;
        }
        if (OH_JSVM_JsonParse(guard.env, rawInputStr, &inputVal) != JSVM_OK || inputVal == nullptr) {
            std::string parseErr = ConsumeExceptionText(guard.env);
            out.error = parseErr.empty()
                ? "Invalid JSON in input_json parameter"
                : ("Invalid JSON in input_json parameter: " + parseErr);
            return out;
        }
    } else {
        OH_JSVM_GetUndefined(guard.env, &inputVal);
    }
    OH_JSVM_SetNamedProperty(guard.env, global, "input", inputVal);

    JSVM_Script script = nullptr;
    std::string compileErr;
    if (!CompileWithOptionalReturnWrapper(guard.env, code, &script, compileErr)) {
        out.logs = logState.buffer;
        out.error = compileErr;
        out.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - startedAt).count();
        return out;
    }

    JSVM_Value resultVal = nullptr;
    JSVM_Status runStatus = OH_JSVM_RunScript(guard.env, script, &resultVal);
    OH_JSVM_PerformMicrotaskCheckpoint(guard.vm);

    std::string runtimeErr = ConsumeExceptionText(guard.env);
    out.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - startedAt).count();
    out.logs = logState.buffer;

    if (runStatus != JSVM_OK || !runtimeErr.empty()) {
        out.ok = false;
        out.error = runtimeErr.empty()
            ? ("Script execution failed (status " + std::to_string(static_cast<int>(runStatus)) + ")")
            : runtimeErr;
        return out;
    }

    std::string formattedResult = FormatValueCompact(guard.env, resultVal, true);
    if (formattedResult.size() > kMaxResultBytes) {
        formattedResult.resize(kMaxResultBytes);
        formattedResult.append("\n...[result truncated at 128 KB]");
    }
    if (out.elapsedMs > budgetMs) {
        if (!out.logs.empty() && out.logs.back() != '\n') {
            out.logs.push_back('\n');
        }
        out.logs.append("[Note] Execution took " + std::to_string(out.elapsedMs) +
                        "ms (exceeded budget " + std::to_string(budgetMs) + "ms)\n");
    }

    out.ok = true;
    out.result = formattedResult;
    return out;
}

}  // namespace swshell
