# Findings & Architectural Decisions

## Key Technical Decisions
1. **Tool Design**:
   - Primary tool: `run_code` with `language: 'python' | 'javascript'` (default: `'python'`).
   - Backwards compatibility: `run_js` retained in `ToolRegistry` and delegates to `RunCodeTool.execute(id, { ...args, language: 'javascript' })`.
   - Tool classification: `READ_ONLY` in `ToolConcurrency.ets` allowing parallel batching.
2. **MicroPython Integration**:
   - Precompiled static library `libmicropython.a` for `arm64-v8a` (`aarch64-linux-ohos`) located in `entry/src/main/cpp/libs/arm64-v8a/`.
   - Toolchain: `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang`.
   - Custom configurations in `mpconfigport.h`:
     - `MICROPY_NLR_SETJMP (1)`
     - `MICROPY_GCREGS_SETJMP (1)`
     - `MICROPY_ENABLE_GC (1)`
     - `MICROPY_PY_JSON (1)`, `MICROPY_PY_RE (1)`, `MICROPY_PY_MATH (1)`, `MICROPY_PY_IO (1)`, `MICROPY_PY_SYS (1)`
     - `MICROPY_ENABLE_VM_ABORT (1)`
3. **Execution & Sandboxing**:
   - Single-call heap isolation: independent GC heap per evaluation (`options.heapLimitBytes`), default 4MB.
   - Global mutex serializes evaluations to protect MicroPython's singleton engine state.
   - Timeout protection: Watchdog timer thread calls `mp_vm_abort()` to break out of infinite loops (`while True`).
   - JSON injection: `__input__` variable bound to `json.loads(...)`.
