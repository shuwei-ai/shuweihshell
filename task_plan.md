# Task Plan: Native C/C++ (libswshell.so) 嵌入 MicroPython 解释器并封装 SuperAgent run_code 工具

## 目标与范围
- 在 `shuweihshell` 的 Native C/C++ 层嵌入 MicroPython 解释器并封装安全隔离沙箱。
- 提供 `py_sandbox.h` / `py_sandbox.cpp`，实现独立 GC 堆、Watchdog 计时器强杀超时、标准输出与异常捕获、JSON 上下文注入。
- 扩充 NAPI 异步桥接与 NativeBridge。
- 实现统一 `RunCodeTool.ets`（`run_code`，支持 `python` 和 `javascript`，默认 `python`），平滑向后兼容现有 `run_js`。
- 注册至 Agent 工具链与 Worker 调度机制中。

## 阶段划分
- [x] **Phase 1: MicroPython 源码接入与交叉编译管线**
  - [x] 编写 `tools/build_micropython.sh` 拉取 MicroPython v1.24.1 并配置 `mpconfigport.h`
  - [x] 交叉编译生成 `libmicropython.a`（`arm64-v8a`，基于 DevEco NDK clang）及 Host 测试库
  - [x] 导出头文件至 `entry/src/main/cpp/vendor/micropython/include`
- [x] **Phase 2: Native C++ 沙箱实现 (`py_sandbox.h` / `py_sandbox.cpp`)**
  - [x] 定义 `py_sandbox.h`，包括 `PySandboxOptions` 与 `PySandboxResult`
  - [x] 实现 `py_sandbox.cpp`：互斥锁保护单例、独立 GC 堆分配、`__input__` 上下文注入、标准输出重定向拦截、独立线程 Watchdog 超时熔断
- [x] **Phase 3: 单元测试套件 (`py_sandbox_test.cpp` & `tools/run_tests.sh`)**
  - [x] 编写基础计算、JSON 转换、超时打断、内存限制异常捕获测试
  - [x] 跑通 Host 端单元测试（全部 8 项单测 100% 通过）
- [x] **Phase 4: CMake 构建集成 (`entry/src/main/cpp/CMakeLists.txt`)**
  - [x] 配置 `libmicropython.a` 预编译静态库导入
  - [x] 将 `py_sandbox.cpp` 编入 `swshell`
- [x] **Phase 5: NAPI 接口与 NativeBridge 扩充**
  - [x] 在 `napi_init.cpp` 中新增 `runPython` 异步 NAPI 接口（`napi_create_async_work`）
  - [x] 在 `NativeBridge.ets` 中增加 `PyEvalNativeResult` 接口定义与 `runPythonNative`
- [x] **Phase 6: ArkTS Agent 工具封装与注册**
  - [x] 实现 `RunCodeTool.ets`，统一支持 `python` 与 `javascript`，处理输出格式化与错误截断
  - [x] 改造 `RunJsTool.ets` 作为向后兼容别名，无缝重定向至 `RunCodeTool`
  - [x] 在 `ToolRegistry.ets`、`ToolConcurrency.ets`、`WorkerPresets.ets` 中注册并优化提示词
  - [x] 编写 `entry/src/test/RunCodeTool.test.ets` 并注册到测试列表
- [x] **Phase 7: 完整验证与验收交付**
  - [x] 运行 host 测试与 native 构建验证
  - [x] 运行 hvigorw assembleApp 全量编译打包，HAP 构建签名成功通过
