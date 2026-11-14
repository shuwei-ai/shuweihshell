/*
 * Native offline Python execution sandbox implementation using CPython 3.13.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "py_sandbox.h"
#include "device_session.h"

#include <Python.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
PyObject* PyInit__socket(void);
PyObject* PyInit__ssl(void);
PyObject* PyInit_math(void);
PyObject* PyInit__json(void);
PyObject* PyInit__datetime(void);
PyObject* PyInit__asyncio(void);
PyObject* PyInit__hashlib(void);
PyObject* PyInit_binascii(void);
PyObject* PyInit_zlib(void);
PyObject* PyInit_select(void);
PyObject* PyInit_unicodedata(void);
PyObject* PyInit_array(void);
PyObject* PyInit__struct(void);
PyObject* PyInit__random(void);
PyObject* PyInit__bisect(void);
PyObject* PyInit__heapq(void);
PyObject* PyInit__pickle(void);
PyObject* PyInit__csv(void);
PyObject* PyInit_cmath(void);
PyObject* PyInit_fcntl(void);
PyObject* PyInit__blake2(void);
}

namespace swshell {

namespace {

constexpr size_t kMaxOutputBytes = 512 * 1024; // 512 KB max output budget

std::mutex gPyExecutionMutex;

static PyObject* PyHdc_IsConnected(PyObject* /*self*/, PyObject* /*args*/)
{
    DeviceSession* session = GetActiveDeviceSession();
    if (session != nullptr && session->IsReady()) {
        Py_RETURN_TRUE;
    }
    Py_RETURN_FALSE;
}

static PyObject* PyHdc_Exec(PyObject* /*self*/, PyObject* args, PyObject* kwargs)
{
    const char* cmd = nullptr;
    const char* bundle = "";
    int timeoutSec = 30;
    static const char* kwlist[] = {"command", "bundle_name", "timeout", nullptr};

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "s|si:exec", const_cast<char**>(kwlist),
                                     &cmd, &bundle, &timeoutSec)) {
        return nullptr;
    }

    DeviceSession* session = GetActiveDeviceSession();
    if (session == nullptr || !session->IsReady()) {
        PyErr_SetString(PyExc_RuntimeError, "HDC bridge is not connected to device daemon.");
        return nullptr;
    }

    std::string cmdStr = cmd ? cmd : "";
    std::string bundleStr = bundle ? bundle : "";
    ExecResult result;
    bool ok = false;

    Py_BEGIN_ALLOW_THREADS
    ok = session->Exec(cmdStr, bundleStr, result, static_cast<unsigned>(timeoutSec > 0 ? timeoutSec : 30));
    Py_END_ALLOW_THREADS

    PyObject* dict = PyDict_New();
    if (!dict) {
        return nullptr;
    }

    PyDict_SetItemString(dict, "ok", ok ? Py_True : Py_False);
    PyObject* pyExitCode = PyLong_FromLong(result.exitCode);
    PyDict_SetItemString(dict, "exit_code", pyExitCode);
    Py_XDECREF(pyExitCode);

    PyObject* pyOut = PyUnicode_FromString(result.output.c_str());
    PyDict_SetItemString(dict, "output", pyOut);
    Py_XDECREF(pyOut);

    PyObject* pyErr = PyUnicode_FromString(result.error.c_str());
    PyDict_SetItemString(dict, "error", pyErr);
    Py_XDECREF(pyErr);

    return dict;
}

static PyMethodDef HdcMethods[] = {
    {"is_connected", (PyCFunction)PyHdc_IsConnected, METH_NOARGS, "Return True if HDC bridge is connected."},
    {"exec", (PyCFunction)PyHdc_Exec, METH_VARARGS | METH_KEYWORDS, "Execute command on device via HDC."},
    {nullptr, nullptr, 0, nullptr}
};

static struct PyModuleDef hdcmodule = {
    PyModuleDef_HEAD_INIT,
    "_hdc",
    "Built-in native HDC bridge channel",
    -1,
    HdcMethods
};

extern "C" PyObject* PyInit__hdc(void)
{
    return PyModule_Create(&hdcmodule);
}

std::string EscapeJsonForPythonLiteral(const std::string &raw)
{
    std::string out;
    out.reserve(raw.size() + 16);
    for (char c : raw) {
        switch (c) {
            case '\\':
                out += "\\\\";
                break;
            case '"':
                out += "\\\"";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                out += c;
                break;
        }
    }
    return out;
}

void RegisterBuiltinModules()
{
    static bool registered = false;
    if (registered) {
        return;
    }
    PyImport_AppendInittab("_socket", PyInit__socket);
    PyImport_AppendInittab("_ssl", PyInit__ssl);
    PyImport_AppendInittab("math", PyInit_math);
    PyImport_AppendInittab("_json", PyInit__json);
    PyImport_AppendInittab("_datetime", PyInit__datetime);
    PyImport_AppendInittab("_asyncio", PyInit__asyncio);
    PyImport_AppendInittab("_hashlib", PyInit__hashlib);
    PyImport_AppendInittab("binascii", PyInit_binascii);
    PyImport_AppendInittab("zlib", PyInit_zlib);
    PyImport_AppendInittab("select", PyInit_select);
    PyImport_AppendInittab("unicodedata", PyInit_unicodedata);
    PyImport_AppendInittab("array", PyInit_array);
    PyImport_AppendInittab("_struct", PyInit__struct);
    PyImport_AppendInittab("_random", PyInit__random);
    PyImport_AppendInittab("_bisect", PyInit__bisect);
    PyImport_AppendInittab("_heapq", PyInit__heapq);
    PyImport_AppendInittab("_pickle", PyInit__pickle);
    PyImport_AppendInittab("_csv", PyInit__csv);
    PyImport_AppendInittab("cmath", PyInit_cmath);
    PyImport_AppendInittab("fcntl", PyInit_fcntl);
    PyImport_AppendInittab("_blake2", PyInit__blake2);
    PyImport_AppendInittab("_hdc", PyInit__hdc);
    registered = true;
}

bool EnsurePythonInitialized(std::string &errOut)
{
    static bool initialized = false;
    static std::string initError;
    if (initialized) {
        return true;
    }
    if (!initError.empty()) {
        errOut = initError;
        return false;
    }

    RegisterBuiltinModules();

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);

    config.site_import = 0;
    config.install_signal_handlers = 0;

    PyStatus status = PyConfig_SetBytesString(&config, &config.program_name, "swshell_python");
    if (PyStatus_Exception(status)) {
        initError = status.err_msg ? status.err_msg : "SetBytesString failed";
        errOut = initError;
        PyConfig_Clear(&config);
        return false;
    }

    config.module_search_paths_set = 1;

    const char *paths[] = {
        "/data/storage/el2/base/haps/entry/files/lib/python3.13",
        "/data/storage/el2/base/haps/entry/files/python313.zip",
        "/data/storage/el2/base/haps/entry/files/site-packages",
        "/data/storage/el2/base/haps/entry/files/workspace",
        "/data/storage/el2/base/haps/entry/files"
    };

    for (const char *p : paths) {
        std::wstring wp;
        const char *cur = p;
        while (*cur) {
            wp.push_back(static_cast<wchar_t>(*cur++));
        }
        PyWideStringList_Append(&config.module_search_paths, wp.c_str());
    }

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        initError = std::string("Py_InitializeFromConfig failed: ") + (status.err_msg ? status.err_msg : "unknown");
        errOut = initError;
        PyConfig_Clear(&config);
        return false;
    }
    PyConfig_Clear(&config);

    const char *setup_sys_path =
        "import sys\n"
        "for p in ['/data/storage/el2/base/haps/entry/files/site-packages', "
        "'/data/storage/el2/base/haps/entry/files/lib/python3.13', "
        "'/data/storage/el2/base/haps/entry/files/python313.zip', "
        "'/data/storage/el2/base/haps/entry/files/workspace']:\n"
        "    if p not in sys.path:\n"
        "        sys.path.insert(0, p)\n"
        "try:\n"
        "    import hdc\n"
        "    hdc._install_compat_hooks()\n"
        "except Exception:\n"
        "    pass\n";
    PyRun_SimpleString(setup_sys_path);

    // Release GIL on main/init thread so worker threads can acquire it via PyGILState_Ensure()
    PyEval_SaveThread();

    initialized = true;
    return true;
}

} // namespace

PySandboxResult ExecutePythonSandbox(const std::string &code, const PySandboxOptions &options)
{
    std::lock_guard<std::mutex> lock(gPyExecutionMutex);
    std::string initErr;
    if (!EnsurePythonInitialized(initErr)) {
        PySandboxResult errResult;
        errResult.ok = false;
        errResult.stderrStr = "Python sandbox init failed: " + initErr;
        errResult.elapsedMs = 0;
        return errResult;
    }

    PyGILState_STATE gstate = PyGILState_Ensure();

    PySandboxResult result;
    auto startTime = std::chrono::steady_clock::now();

    uint32_t timeoutMs = options.timeoutMs > 0 ? options.timeoutMs : 5000;
    std::atomic<bool> isFinished{false};
    std::atomic<bool> didTimeout{false};
    std::mutex cvMutex;
    std::condition_variable cv;

    std::thread watchdog([&]() {
        std::unique_lock<std::mutex> cvLock(cvMutex);
        if (!cv.wait_for(cvLock, std::chrono::milliseconds(timeoutMs),
                         [&]() { return isFinished.load(); })) {
            didTimeout.store(true);
            PyErr_SetInterrupt();
        }
    });

    PyObject *mainMod = PyImport_AddModule("__main__");
    PyObject *mainDict = PyModule_GetDict(mainMod);

    // Setup stdout/stderr redirection and clear previous output variables
    std::string wrapper =
        "import sys, io, traceback\n"
        "sys._stdout_buf = io.StringIO()\n"
        "sys._stderr_buf = io.StringIO()\n"
        "sys._orig_stdout = sys.stdout\n"
        "sys._orig_stderr = sys.stderr\n"
        "sys.stdout = sys._stdout_buf\n"
        "sys.stderr = sys._stderr_buf\n";

    if (!options.inputJson.empty()) {
        wrapper += "import json\n__input__ = json.loads(\"" +
                   EscapeJsonForPythonLiteral(options.inputJson) + "\")\n";
    }

    PyRun_SimpleString(wrapper.c_str());

    // Execute user code
    PyObject *evalResult = PyRun_String(code.c_str(), Py_file_input, mainDict, mainDict);
    bool execOk = true;

    if (evalResult == nullptr) {
        execOk = false;
        if (PyErr_Occurred()) {
            PyErr_Print();
        }
    } else {
        Py_DECREF(evalResult);
    }

    // Teardown stdout/stderr redirection and extract buffers
    const char *teardown =
        "sys.stdout = sys._orig_stdout\n"
        "sys.stderr = sys._orig_stderr\n"
        "__out_str__ = sys._stdout_buf.getvalue()\n"
        "__err_str__ = sys._stderr_buf.getvalue()\n";
    PyRun_SimpleString(teardown);

    PyObject *outObj = PyDict_GetItemString(mainDict, "__out_str__");
    if (outObj && PyUnicode_Check(outObj)) {
        result.stdoutStr = PyUnicode_AsUTF8(outObj);
    }
    PyObject *errObj = PyDict_GetItemString(mainDict, "__err_str__");
    if (errObj && PyUnicode_Check(errObj)) {
        result.stderrStr = PyUnicode_AsUTF8(errObj);
    }

    // Truncate output if it exceeds budget
    if (result.stdoutStr.size() > kMaxOutputBytes) {
        result.stdoutStr = result.stdoutStr.substr(0, kMaxOutputBytes) + "\n...[stdout truncated]";
    }
    if (result.stderrStr.size() > kMaxOutputBytes) {
        result.stderrStr = result.stderrStr.substr(0, kMaxOutputBytes) + "\n...[stderr truncated]";
    }

    {
        std::lock_guard<std::mutex> cvLock(cvMutex);
        isFinished.store(true);
    }
    cv.notify_one();
    if (watchdog.joinable()) {
        watchdog.join();
    }

    auto endTime = std::chrono::steady_clock::now();
    result.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime).count();
    result.timedOut = didTimeout.load();

    if (result.timedOut) {
        result.ok = false;
        result.stderrStr = "Execution timed out after " + std::to_string(timeoutMs) + "ms\n" + result.stderrStr;
    } else if (!execOk) {
        result.ok = false;
    } else {
        result.ok = true;
    }

    PyGILState_Release(gstate);
    return result;
}

} // namespace swshell
