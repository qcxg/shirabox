#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>

#include "../../windows/runner/process_job.h"

namespace {

std::wstring CurrentExecutable() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length =
      GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) return L"";
  return std::wstring(buffer.data(), length);
}

std::wstring Quote(const std::wstring& value) { return L"\"" + value + L"\""; }

int RunParent() {
  const std::wstring executable = CurrentExecutable();
  if (executable.empty()) return 20;
  std::wstring command = Quote(executable) + L" --child";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  // The child is created immediately. The smoke therefore proves the parent
  // was already in its Job before any parent code could create descendants.
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) {
    std::cout << "0\n" << std::flush;
    return 21;
  }
  std::cout << child.dwProcessId << "\n" << std::flush;
  std::cerr << "parent-ready\n" << std::flush;
  CloseHandle(child.hThread);
  WaitForSingleObject(child.hProcess, INFINITE);
  CloseHandle(child.hProcess);
  return 0;
}

int RunArgumentProbe(int argc, wchar_t** argv) {
  std::string input;
  std::getline(std::cin, input);
  const bool arguments_ok =
      argc == 6 && std::wstring(argv[2]) == L"space value" &&
      std::wstring(argv[3]) == L"quote\"value" &&
      std::wstring(argv[4]) == L"trailing\\" &&
      std::wstring(argv[5]).empty();
  if (!arguments_ok || input != "stdin-value") return 30;
  std::cout << "argv-stdin-ok\n" << std::flush;
  std::cerr << "stderr-ok\n" << std::flush;
  return 0;
}

// Opt-in reproducer: use a private ADB server port so the developer's regular
// server and device connections are never stopped by this probe.
int RunAdbBootstrapProbe(const std::wstring& adb, const std::wstring& port) {
  ProcessJobManager jobs;
  std::mutex mutex;
  std::condition_variable changed;
  bool exited = false;
  DWORD exit_code = STILL_ACTIVE;
  jobs.SetEventCallback([&](const ProcessJobEvent& event) {
    if (event.kind == ProcessJobEventKind::kExit) {
      std::lock_guard<std::mutex> lock(mutex);
      exited = true;
      exit_code = event.exit_code;
      changed.notify_all();
    }
  });
  ProcessLaunchRequest request;
  request.executable = adb;
  request.arguments = {L"-P", port, L"start-server"};
  const auto process = jobs.Launch(request);
  if (!process.success || !jobs.Resume(process.token).success) return 40;
  bool completed;
  {
    std::unique_lock<std::mutex> lock(mutex);
    completed = changed.wait_for(lock, std::chrono::seconds(10),
                                 [&]() { return exited; });
  }
  if (!completed) jobs.Terminate(process.token, 41);
  if (!jobs.Release(process.token).success) return 42;
  std::cout << "owned ADB bootstrap completed=" << completed
            << " exit=" << exit_code << std::endl;
  return completed && exit_code == 0 ? 0 : 43;
}

int RunSmoke() {
  const std::wstring executable = CurrentExecutable();
  if (executable.empty()) return 1;

  ProcessJobManager jobs;
  std::mutex events_mutex;
  std::condition_variable events_changed;
  std::string stdout_text;
  std::string stderr_text;
  bool stdout_closed = false;
  bool stderr_closed = false;
  bool exit_seen = false;
  DWORD observed_exit = STILL_ACTIVE;

  jobs.SetEventCallback([&](const ProcessJobEvent& event) {
    std::lock_guard<std::mutex> lock(events_mutex);
    switch (event.kind) {
      case ProcessJobEventKind::kStdout:
        stdout_text.append(event.data.begin(), event.data.end());
        break;
      case ProcessJobEventKind::kStderr:
        stderr_text.append(event.data.begin(), event.data.end());
        break;
      case ProcessJobEventKind::kStdoutClosed:
        stdout_closed = true;
        break;
      case ProcessJobEventKind::kStderrClosed:
        stderr_closed = true;
        break;
      case ProcessJobEventKind::kExit:
        exit_seen = true;
        observed_exit = event.exit_code;
        break;
      case ProcessJobEventKind::kStreamError:
        break;
    }
    events_changed.notify_all();
  });

  ProcessLaunchRequest probe_request;
  probe_request.executable = executable;
  probe_request.arguments = {L"--argv-probe", L"space value", L"quote\"value",
                             L"trailing\\", L""};
  const ProcessJobResult probe = jobs.Launch(probe_request);
  if (!probe.success || !jobs.Resume(probe.token).success) return 2;
  const std::vector<uint8_t> stdin_data = {'s', 't', 'd', 'i', 'n', '-', 'v',
                                           'a', 'l', 'u', 'e', '\n'};
  if (!jobs.WriteStdin(probe.token, stdin_data).success ||
      !jobs.CloseStdin(probe.token).success) {
    jobs.Terminate(probe.token, 3);
    jobs.Release(probe.token);
    return 3;
  }
  {
    std::unique_lock<std::mutex> lock(events_mutex);
    if (!events_changed.wait_for(lock, std::chrono::seconds(5), [&]() {
          return exit_seen && stdout_closed && stderr_closed;
        }) ||
        observed_exit != 0 || stdout_text != "argv-stdin-ok\r\n" ||
        stderr_text != "stderr-ok\r\n") {
      std::cerr << "probe exit=" << observed_exit << " stdout=" << stdout_text
                << " stderr=" << stderr_text << std::endl;
      jobs.Terminate(probe.token, 4);
      jobs.Release(probe.token);
      return 4;
    }
  }
  if (!jobs.Release(probe.token).success) return 5;
  {
    std::lock_guard<std::mutex> lock(events_mutex);
    stdout_text.clear();
    stderr_text.clear();
    stdout_closed = false;
    stderr_closed = false;
    exit_seen = false;
    observed_exit = STILL_ACTIVE;
  }

  ProcessLaunchRequest request;
  request.executable = executable;
  request.arguments = {L"--parent"};
  const ProcessJobResult launched = jobs.Launch(request);
  if (!launched.success || launched.token == 0 || launched.process_id == 0) {
    return 6;
  }
  const ProcessJobResult resumed = jobs.Resume(launched.token);
  if (!resumed.success) {
    jobs.Release(launched.token);
    return 7;
  }

  DWORD child_id = 0;
  {
    std::unique_lock<std::mutex> lock(events_mutex);
    if (!events_changed.wait_for(lock, std::chrono::seconds(5), [&]() {
          return stdout_text.find('\n') != std::string::npos;
        })) {
      jobs.Terminate(launched.token, 4);
      jobs.Release(launched.token);
      return 8;
    }
    child_id =
        static_cast<DWORD>(std::strtoul(stdout_text.c_str(), nullptr, 10));
  }
  if (child_id == 0) {
    jobs.Terminate(launched.token, 5);
    jobs.Release(launched.token);
    return 9;
  }

  HANDLE parent_process = OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
      launched.process_id);
  HANDLE child_process = OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, child_id);
  if (parent_process == nullptr || child_process == nullptr) {
    if (parent_process != nullptr) CloseHandle(parent_process);
    if (child_process != nullptr) CloseHandle(child_process);
    jobs.Terminate(launched.token, 6);
    jobs.Release(launched.token);
    return 10;
  }

  constexpr UINT kExitCode = 0x53484258;
  if (!jobs.Terminate(launched.token, kExitCode).success) return 11;
  if (WaitForSingleObject(parent_process, 5000) != WAIT_OBJECT_0) return 12;
  if (WaitForSingleObject(child_process, 5000) != WAIT_OBJECT_0) return 13;

  {
    std::unique_lock<std::mutex> lock(events_mutex);
    if (!events_changed.wait_for(lock, std::chrono::seconds(5), [&]() {
          return exit_seen && stdout_closed && stderr_closed;
        })) {
      return 14;
    }
    if (observed_exit != kExitCode ||
        stderr_text.find("parent-ready") == std::string::npos) {
      return 15;
    }
  }

  DWORD parent_exit = STILL_ACTIVE;
  DWORD child_exit = STILL_ACTIVE;
  GetExitCodeProcess(parent_process, &parent_exit);
  GetExitCodeProcess(child_process, &child_exit);
  CloseHandle(parent_process);
  CloseHandle(child_process);
  if (!jobs.Release(launched.token).success) return 16;
  if (parent_exit == STILL_ACTIVE || child_exit == STILL_ACTIVE) return 17;
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc == 4 && std::wstring(argv[1]) == L"--adb-bootstrap-probe") {
    return RunAdbBootstrapProbe(argv[2], argv[3]);
  }
  if (argc == 2 && std::wstring(argv[1]) == L"--child") {
    Sleep(30000);
    return 0;
  }
  if (argc == 2 && std::wstring(argv[1]) == L"--parent") {
    return RunParent();
  }
  if (argc >= 2 && std::wstring(argv[1]) == L"--argv-probe") {
    return RunArgumentProbe(argc, argv);
  }
  return RunSmoke();
}
