#include "process_job.h"

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <limits>
#include <thread>
#include <utility>

namespace {

constexpr size_t kPipeBufferBytes = 64 * 1024;
constexpr size_t kMaxPendingStdinBytes = 1024 * 1024;

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = nullptr) : handle_(handle) {}
  ~ScopedHandle() { reset(); }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  ScopedHandle(ScopedHandle&& other) noexcept : handle_(other.release()) {}
  ScopedHandle& operator=(ScopedHandle&& other) noexcept {
    if (this != &other) reset(other.release());
    return *this;
  }

  HANDLE get() const { return handle_; }

  HANDLE release() {
    const HANDLE value = handle_;
    handle_ = nullptr;
    return value;
  }

  void reset(HANDLE handle = nullptr) {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_;
};

class ScopedAttributeList {
 public:
  ~ScopedAttributeList() {
    if (value_ != nullptr) DeleteProcThreadAttributeList(value_);
  }

  ScopedAttributeList(const ScopedAttributeList&) = delete;
  ScopedAttributeList& operator=(const ScopedAttributeList&) = delete;
  ScopedAttributeList() = default;

  bool Initialize() {
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    if (bytes == 0) return false;
    storage_.resize(bytes);
    value_ = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage_.data());
    if (!InitializeProcThreadAttributeList(value_, 1, 0, &bytes)) {
      value_ = nullptr;
      return false;
    }
    return true;
  }

  LPPROC_THREAD_ATTRIBUTE_LIST get() const { return value_; }

 private:
  std::vector<uint8_t> storage_;
  LPPROC_THREAD_ATTRIBUTE_LIST value_ = nullptr;
};

ProcessJobResult ConfigureJob(ScopedHandle* job) {
  job->reset(CreateJobObjectW(nullptr, nullptr));
  if (job->get() == nullptr) {
    return ProcessJobResult::Error("Unable to create a Windows Job Object.",
                                   GetLastError());
  }

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job->get(), JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) {
    return ProcessJobResult::Error("Unable to configure the Windows Job Object.",
                                   GetLastError());
  }
  return ProcessJobResult::Ok();
}

std::wstring QuoteWindowsArgument(const std::wstring& value) {
  if (!value.empty() && value.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return value;
  }

  std::wstring quoted(1, L'\"');
  size_t backslashes = 0;
  for (const wchar_t character : value) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'\"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(L'\"');
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(character);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'\"');
  return quoted;
}

std::wstring BuildCommandLine(const ProcessLaunchRequest& request) {
  std::wstring command = QuoteWindowsArgument(request.executable);
  for (const auto& argument : request.arguments) {
    command.push_back(L' ');
    command.append(QuoteWindowsArgument(argument));
  }
  return command;
}

std::vector<wchar_t> BuildEnvironmentBlock(
    const std::vector<std::pair<std::wstring, std::wstring>>& values) {
  std::vector<std::pair<std::wstring, std::wstring>> sorted(values);
  std::sort(sorted.begin(), sorted.end(), [](const auto& left, const auto& right) {
    return _wcsicmp(left.first.c_str(), right.first.c_str()) < 0;
  });

  size_t characters = 1;
  for (const auto& entry : sorted) {
    characters += entry.first.size() + 1 + entry.second.size() + 1;
  }
  if (sorted.empty()) ++characters;

  std::vector<wchar_t> block;
  block.reserve(characters);
  for (const auto& entry : sorted) {
    block.insert(block.end(), entry.first.begin(), entry.first.end());
    block.push_back(L'=');
    block.insert(block.end(), entry.second.begin(), entry.second.end());
    block.push_back(L'\0');
  }
  block.push_back(L'\0');
  if (sorted.empty()) block.push_back(L'\0');
  return block;
}

bool HasEmbeddedNull(const std::wstring& value) {
  return value.find(L'\0') != std::wstring::npos;
}

ProcessJobResult ResolveExecutable(const std::wstring& requested,
                                   std::wstring* resolved) {
  if (requested.find_first_of(L"\\/:") != std::wstring::npos) {
    *resolved = requested;
    return ProcessJobResult::Ok();
  }

  const size_t final_separator = requested.find_last_of(L"\\/");
  const size_t final_dot = requested.find_last_of(L'.');
  const bool has_extension =
      final_dot != std::wstring::npos &&
      (final_separator == std::wstring::npos || final_dot > final_separator);
  const wchar_t* extension = has_extension ? nullptr : L".exe";
  const DWORD required =
      SearchPathW(nullptr, requested.c_str(), extension, 0, nullptr, nullptr);
  if (required == 0) {
    return ProcessJobResult::Error("Unable to resolve the executable on PATH.",
                                   GetLastError());
  }
  std::vector<wchar_t> buffer(static_cast<size_t>(required) + 1);
  const DWORD written = SearchPathW(nullptr, requested.c_str(), extension,
                                    static_cast<DWORD>(buffer.size()),
                                    buffer.data(), nullptr);
  if (written == 0 || written >= buffer.size()) {
    return ProcessJobResult::Error("Unable to resolve the executable on PATH.",
                                   GetLastError());
  }
  *resolved = std::wstring(buffer.data(), written);
  return ProcessJobResult::Ok();
}

}  // namespace

struct ProcessJobManager::Entry {
  uint64_t token = 0;
  DWORD process_id = 0;
  HANDLE job = nullptr;
  HANDLE process = nullptr;
  HANDLE primary_thread = nullptr;
  HANDLE stdout_read = nullptr;
  HANDLE stderr_read = nullptr;
  HANDLE stdin_write = nullptr;

  std::mutex state_mutex;
  bool resumed = false;

  std::mutex stdin_mutex;
  std::condition_variable stdin_changed;
  std::deque<std::vector<uint8_t>> stdin_queue;
  size_t pending_stdin_bytes = 0;
  bool stdin_close_requested = false;

  std::thread stdout_thread;
  std::thread stderr_thread;
  std::thread stdin_thread;
  std::thread wait_thread;
};

ProcessJobResult ProcessJobResult::Ok(uint64_t token, DWORD process_id) {
  ProcessJobResult result;
  result.success = true;
  result.token = token;
  result.process_id = process_id;
  return result;
}

ProcessJobResult ProcessJobResult::Error(std::string message,
                                         DWORD windows_error) {
  ProcessJobResult result;
  result.message = std::move(message);
  result.windows_error = windows_error;
  return result;
}

ProcessJobManager::~ProcessJobManager() { CloseAll(); }

uint64_t ProcessJobManager::NextTokenLocked() {
  uint64_t token = next_token_++;
  if (token == 0) token = next_token_++;
  return token;
}

std::shared_ptr<ProcessJobManager::Entry> ProcessJobManager::Find(
    uint64_t token) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto entry = jobs_.find(token);
  return entry == jobs_.end() ? nullptr : entry->second;
}

ProcessJobResult ProcessJobManager::Attach(DWORD process_id) {
  if (process_id == 0) {
    return ProcessJobResult::Error("The process ID must be positive.",
                                   ERROR_INVALID_PARAMETER);
  }

  ScopedHandle process(OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE |
                                       PROCESS_QUERY_LIMITED_INFORMATION |
                                       SYNCHRONIZE,
                                   FALSE, process_id));
  if (process.get() == nullptr) {
    return ProcessJobResult::Error("Unable to open the child process.",
                                   GetLastError());
  }

  DWORD process_exit_code = 0;
  if (!GetExitCodeProcess(process.get(), &process_exit_code)) {
    return ProcessJobResult::Error("Unable to query the child process.",
                                   GetLastError());
  }
  if (process_exit_code != STILL_ACTIVE) {
    return ProcessJobResult::Error("The child process has already exited.",
                                   ERROR_PROCESS_ABORTED);
  }

  ScopedHandle job;
  const ProcessJobResult configured = ConfigureJob(&job);
  if (!configured.success) return configured;
  if (!AssignProcessToJobObject(job.get(), process.get())) {
    return ProcessJobResult::Error(
        "Unable to assign the child process to the Windows Job Object.",
        GetLastError());
  }

  auto owned = std::make_shared<Entry>();
  owned->process_id = process_id;
  owned->job = job.release();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    owned->token = NextTokenLocked();
    jobs_.emplace(owned->token, owned);
  }
  return ProcessJobResult::Ok(owned->token, process_id);
}

ProcessJobResult ProcessJobManager::Launch(
    const ProcessLaunchRequest& request) {
  if (request.executable.empty() || HasEmbeddedNull(request.executable)) {
    return ProcessJobResult::Error("The executable path is invalid.",
                                   ERROR_INVALID_PARAMETER);
  }
  for (const auto& argument : request.arguments) {
    if (HasEmbeddedNull(argument)) {
      return ProcessJobResult::Error("A process argument contains NUL.",
                                     ERROR_INVALID_PARAMETER);
    }
  }
  if (request.working_directory.has_value() &&
      HasEmbeddedNull(request.working_directory.value())) {
    return ProcessJobResult::Error("The working directory contains NUL.",
                                   ERROR_INVALID_PARAMETER);
  }
  for (const auto& variable : request.environment) {
    if (variable.first.empty() || variable.first.find(L'=') != std::wstring::npos ||
        HasEmbeddedNull(variable.first) || HasEmbeddedNull(variable.second)) {
      return ProcessJobResult::Error("The process environment is invalid.",
                                     ERROR_INVALID_PARAMETER);
    }
  }

  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;

  HANDLE stdout_read_raw = nullptr;
  HANDLE stdout_write_raw = nullptr;
  if (!CreatePipe(&stdout_read_raw, &stdout_write_raw, &security, 0)) {
    return ProcessJobResult::Error("Unable to create the stdout pipe.",
                                   GetLastError());
  }
  ScopedHandle stdout_read(stdout_read_raw);
  ScopedHandle stdout_write(stdout_write_raw);

  HANDLE stderr_read_raw = nullptr;
  HANDLE stderr_write_raw = nullptr;
  if (!CreatePipe(&stderr_read_raw, &stderr_write_raw, &security, 0)) {
    return ProcessJobResult::Error("Unable to create the stderr pipe.",
                                   GetLastError());
  }
  ScopedHandle stderr_read(stderr_read_raw);
  ScopedHandle stderr_write(stderr_write_raw);

  HANDLE stdin_read_raw = nullptr;
  HANDLE stdin_write_raw = nullptr;
  if (!CreatePipe(&stdin_read_raw, &stdin_write_raw, &security, 0)) {
    return ProcessJobResult::Error("Unable to create the stdin pipe.",
                                   GetLastError());
  }
  ScopedHandle stdin_read(stdin_read_raw);
  ScopedHandle stdin_write(stdin_write_raw);

  if (!SetHandleInformation(stdout_read.get(), HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(stderr_read.get(), HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(stdin_write.get(), HANDLE_FLAG_INHERIT, 0)) {
    return ProcessJobResult::Error("Unable to protect parent pipe handles.",
                                   GetLastError());
  }

  ScopedHandle job;
  const ProcessJobResult configured = ConfigureJob(&job);
  if (!configured.success) return configured;

  ScopedAttributeList attributes;
  if (!attributes.Initialize()) {
    return ProcessJobResult::Error(
        "Unable to initialize the inherited-handle list.", GetLastError());
  }
  HANDLE inherited_handles[] = {stdin_read.get(), stdout_write.get(),
                                stderr_write.get()};
  if (!UpdateProcThreadAttribute(
          attributes.get(), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
          inherited_handles, sizeof(inherited_handles), nullptr, nullptr)) {
    return ProcessJobResult::Error("Unable to restrict inherited handles.",
                                   GetLastError());
  }

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = stdin_read.get();
  startup.StartupInfo.hStdOutput = stdout_write.get();
  startup.StartupInfo.hStdError = stderr_write.get();
  startup.lpAttributeList = attributes.get();

  std::wstring resolved_executable;
  const ProcessJobResult resolved =
      ResolveExecutable(request.executable, &resolved_executable);
  if (!resolved.success) return resolved;

  std::wstring command = BuildCommandLine(request);
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  std::vector<wchar_t> environment;
  if (request.has_environment) {
    environment = BuildEnvironmentBlock(request.environment);
  }

  PROCESS_INFORMATION process_info{};
  const DWORD flags = CREATE_SUSPENDED | CREATE_NO_WINDOW |
                      EXTENDED_STARTUPINFO_PRESENT |
                      (request.has_environment ? CREATE_UNICODE_ENVIRONMENT : 0);
  const wchar_t* working_directory = request.working_directory.has_value()
                                         ? request.working_directory->c_str()
                                         : nullptr;
  if (!CreateProcessW(
          resolved_executable.c_str(), mutable_command.data(), nullptr, nullptr,
          TRUE, flags,
          request.has_environment ? environment.data() : nullptr,
          working_directory, &startup.StartupInfo, &process_info)) {
    return ProcessJobResult::Error("Unable to create the owned process.",
                                   GetLastError());
  }
  ScopedHandle process(process_info.hProcess);
  ScopedHandle primary_thread(process_info.hThread);

  if (!AssignProcessToJobObject(job.get(), process.get())) {
    const DWORD error = GetLastError();
    TerminateProcess(process.get(), ERROR_PROCESS_ABORTED);
    WaitForSingleObject(process.get(), 5000);
    return ProcessJobResult::Error(
        "Unable to atomically assign the child to its Windows Job Object.",
        error);
  }

  // The child owns these inherited ends. Closing the parent copies is required
  // for EOF to become observable after the process tree exits.
  stdin_read.reset();
  stdout_write.reset();
  stderr_write.reset();

  auto owned = std::make_shared<Entry>();
  owned->process_id = process_info.dwProcessId;
  owned->job = job.release();
  owned->process = process.release();
  owned->primary_thread = primary_thread.release();
  owned->stdout_read = stdout_read.release();
  owned->stderr_read = stderr_read.release();
  owned->stdin_write = stdin_write.release();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    owned->token = NextTokenLocked();
    jobs_.emplace(owned->token, owned);
  }
  return ProcessJobResult::Ok(owned->token, owned->process_id);
}

ProcessJobResult ProcessJobManager::Resume(uint64_t token) {
  const auto entry = Find(token);
  if (entry == nullptr || entry->process == nullptr ||
      entry->primary_thread == nullptr) {
    return ProcessJobResult::Error("The owned process token is not resumable.",
                                   ERROR_NOT_FOUND);
  }

  std::lock_guard<std::mutex> state_lock(entry->state_mutex);
  if (entry->resumed) {
    return ProcessJobResult::Error("The owned process is already running.",
                                   ERROR_INVALID_STATE);
  }

  try {
    entry->stdout_thread = std::thread([this, entry]() {
      std::vector<uint8_t> buffer(kPipeBufferBytes);
      DWORD bytes_read = 0;
      DWORD error = ERROR_SUCCESS;
      while (true) {
        if (!ReadFile(entry->stdout_read, buffer.data(),
                      static_cast<DWORD>(buffer.size()), &bytes_read, nullptr)) {
          error = GetLastError();
          break;
        }
        if (bytes_read == 0) break;
        ProcessJobEvent event;
        event.token = entry->token;
        event.kind = ProcessJobEventKind::kStdout;
        event.data.assign(buffer.begin(), buffer.begin() + bytes_read);
        Emit(std::move(event));
      }
      CloseHandle(entry->stdout_read);
      entry->stdout_read = nullptr;
      if (error != ERROR_BROKEN_PIPE && error != ERROR_SUCCESS) {
        ProcessJobEvent event;
        event.token = entry->token;
        event.kind = ProcessJobEventKind::kStreamError;
        event.windows_error = error;
        event.is_stderr = false;
        Emit(std::move(event));
      }
      ProcessJobEvent closed;
      closed.token = entry->token;
      closed.kind = ProcessJobEventKind::kStdoutClosed;
      Emit(std::move(closed));
    });

    entry->stderr_thread = std::thread([this, entry]() {
      std::vector<uint8_t> buffer(kPipeBufferBytes);
      DWORD bytes_read = 0;
      DWORD error = ERROR_SUCCESS;
      while (true) {
        if (!ReadFile(entry->stderr_read, buffer.data(),
                      static_cast<DWORD>(buffer.size()), &bytes_read, nullptr)) {
          error = GetLastError();
          break;
        }
        if (bytes_read == 0) break;
        ProcessJobEvent event;
        event.token = entry->token;
        event.kind = ProcessJobEventKind::kStderr;
        event.data.assign(buffer.begin(), buffer.begin() + bytes_read);
        Emit(std::move(event));
      }
      CloseHandle(entry->stderr_read);
      entry->stderr_read = nullptr;
      if (error != ERROR_BROKEN_PIPE && error != ERROR_SUCCESS) {
        ProcessJobEvent event;
        event.token = entry->token;
        event.kind = ProcessJobEventKind::kStreamError;
        event.windows_error = error;
        event.is_stderr = true;
        Emit(std::move(event));
      }
      ProcessJobEvent closed;
      closed.token = entry->token;
      closed.kind = ProcessJobEventKind::kStderrClosed;
      Emit(std::move(closed));
    });

    entry->stdin_thread = std::thread([entry]() {
      while (true) {
        std::vector<uint8_t> chunk;
        {
          std::unique_lock<std::mutex> lock(entry->stdin_mutex);
          entry->stdin_changed.wait(lock, [entry]() {
            return entry->stdin_close_requested || !entry->stdin_queue.empty();
          });
          if (entry->stdin_queue.empty()) {
            if (entry->stdin_close_requested) break;
            continue;
          }
          chunk = std::move(entry->stdin_queue.front());
          entry->stdin_queue.pop_front();
          entry->pending_stdin_bytes -= chunk.size();
        }

        size_t offset = 0;
        while (offset < chunk.size()) {
          DWORD written = 0;
          const DWORD requested = static_cast<DWORD>(std::min<size_t>(
              chunk.size() - offset, std::numeric_limits<DWORD>::max()));
          if (!WriteFile(entry->stdin_write, chunk.data() + offset, requested,
                         &written, nullptr) || written == 0) {
            offset = chunk.size();
            std::lock_guard<std::mutex> lock(entry->stdin_mutex);
            entry->stdin_close_requested = true;
            entry->stdin_queue.clear();
            entry->pending_stdin_bytes = 0;
            break;
          }
          offset += written;
        }
      }
      {
        std::lock_guard<std::mutex> lock(entry->stdin_mutex);
        CloseHandle(entry->stdin_write);
        entry->stdin_write = nullptr;
      }
    });

    entry->wait_thread = std::thread([this, entry]() {
      WaitForSingleObject(entry->process, INFINITE);
      DWORD exit_code = ERROR_PROCESS_ABORTED;
      GetExitCodeProcess(entry->process, &exit_code);
      {
        std::lock_guard<std::mutex> lock(entry->stdin_mutex);
        entry->stdin_close_requested = true;
      }
      entry->stdin_changed.notify_all();
      if (entry->stdout_thread.joinable()) entry->stdout_thread.join();
      if (entry->stderr_thread.joinable()) entry->stderr_thread.join();
      if (entry->stdin_thread.joinable()) entry->stdin_thread.join();

      ProcessJobEvent event;
      event.token = entry->token;
      event.kind = ProcessJobEventKind::kExit;
      event.exit_code = exit_code;
      Emit(std::move(event));
    });
  } catch (...) {
    TerminateJobObject(entry->job, ERROR_NOT_ENOUGH_MEMORY);
    {
      std::lock_guard<std::mutex> lock(entry->stdin_mutex);
      entry->stdin_close_requested = true;
    }
    entry->stdin_changed.notify_all();
    if (entry->wait_thread.joinable()) {
      entry->wait_thread.join();
    } else {
      WaitForSingleObject(entry->process, 5000);
      if (entry->stdout_thread.joinable()) entry->stdout_thread.join();
      if (entry->stderr_thread.joinable()) entry->stderr_thread.join();
      if (entry->stdin_thread.joinable()) entry->stdin_thread.join();
    }
    return ProcessJobResult::Error("Unable to start process I/O workers.",
                                   ERROR_NOT_ENOUGH_MEMORY);
  }

  if (ResumeThread(entry->primary_thread) == static_cast<DWORD>(-1)) {
    const DWORD error = GetLastError();
    TerminateJobObject(entry->job, ERROR_PROCESS_ABORTED);
    CloseHandle(entry->primary_thread);
    entry->primary_thread = nullptr;
    return ProcessJobResult::Error("Unable to resume the owned process.", error);
  }
  CloseHandle(entry->primary_thread);
  entry->primary_thread = nullptr;
  entry->resumed = true;
  return ProcessJobResult::Ok(entry->token, entry->process_id);
}

ProcessJobResult ProcessJobManager::WriteStdin(
    uint64_t token, const std::vector<uint8_t>& data) {
  const auto entry = Find(token);
  if (entry == nullptr || entry->process == nullptr) {
    return ProcessJobResult::Error("The owned process token is unknown.",
                                   ERROR_NOT_FOUND);
  }
  if (data.empty()) return ProcessJobResult::Ok(token, entry->process_id);

  std::lock_guard<std::mutex> lock(entry->stdin_mutex);
  if (entry->stdin_close_requested || entry->stdin_write == nullptr) {
    return ProcessJobResult::Error("The owned process stdin is closed.",
                                   ERROR_BROKEN_PIPE);
  }
  if (data.size() > kMaxPendingStdinBytes -
                        std::min(kMaxPendingStdinBytes,
                                 entry->pending_stdin_bytes)) {
    return ProcessJobResult::Error("The owned process stdin queue is full.",
                                   ERROR_NOT_ENOUGH_MEMORY);
  }
  entry->stdin_queue.push_back(data);
  entry->pending_stdin_bytes += data.size();
  entry->stdin_changed.notify_one();
  return ProcessJobResult::Ok(token, entry->process_id);
}

ProcessJobResult ProcessJobManager::CloseStdin(uint64_t token) {
  const auto entry = Find(token);
  if (entry == nullptr || entry->process == nullptr) {
    return ProcessJobResult::Error("The owned process token is unknown.",
                                   ERROR_NOT_FOUND);
  }
  {
    std::lock_guard<std::mutex> lock(entry->stdin_mutex);
    entry->stdin_close_requested = true;
  }
  entry->stdin_changed.notify_all();
  return ProcessJobResult::Ok(token, entry->process_id);
}

ProcessJobResult ProcessJobManager::Terminate(uint64_t token, UINT exit_code) {
  const auto entry = Find(token);
  if (entry == nullptr) {
    return ProcessJobResult::Error("The process job token is unknown.",
                                   ERROR_NOT_FOUND);
  }
  if (!TerminateJobObject(entry->job, exit_code)) {
    return ProcessJobResult::Error("Unable to terminate the process job.",
                                   GetLastError());
  }
  return ProcessJobResult::Ok(token, entry->process_id);
}

void ProcessJobManager::CloseEntry(const std::shared_ptr<Entry>& entry,
                                   bool terminate) {
  if (terminate && entry->job != nullptr) {
    TerminateJobObject(entry->job, ERROR_PROCESS_ABORTED);
  }
  {
    std::lock_guard<std::mutex> lock(entry->stdin_mutex);
    entry->stdin_close_requested = true;
  }
  entry->stdin_changed.notify_all();

  if (entry->wait_thread.joinable()) {
    entry->wait_thread.join();
  } else if (entry->process != nullptr) {
    WaitForSingleObject(entry->process, 5000);
    if (entry->stdout_thread.joinable()) entry->stdout_thread.join();
    if (entry->stderr_thread.joinable()) entry->stderr_thread.join();
    if (entry->stdin_thread.joinable()) entry->stdin_thread.join();
  }

  if (entry->primary_thread != nullptr) CloseHandle(entry->primary_thread);
  if (entry->stdout_read != nullptr) CloseHandle(entry->stdout_read);
  if (entry->stderr_read != nullptr) CloseHandle(entry->stderr_read);
  if (entry->stdin_write != nullptr) CloseHandle(entry->stdin_write);
  if (entry->process != nullptr) CloseHandle(entry->process);
  if (entry->job != nullptr) CloseHandle(entry->job);
  entry->primary_thread = nullptr;
  entry->stdout_read = nullptr;
  entry->stderr_read = nullptr;
  entry->stdin_write = nullptr;
  entry->process = nullptr;
  entry->job = nullptr;
}

ProcessJobResult ProcessJobManager::Release(uint64_t token) {
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = jobs_.find(token);
    if (found == jobs_.end()) {
      return ProcessJobResult::Error("The process job token is unknown.",
                                     ERROR_NOT_FOUND);
    }
    entry = found->second;
    jobs_.erase(found);
  }

  bool terminate = false;
  if (entry->process != nullptr) {
    terminate = WaitForSingleObject(entry->process, 0) != WAIT_OBJECT_0;
  }
  CloseEntry(entry, terminate);
  return ProcessJobResult::Ok(token, entry->process_id);
}

void ProcessJobManager::SetEventCallback(EventCallback callback) {
  std::lock_guard<std::mutex> lock(event_mutex_);
  event_callback_ = std::move(callback);
}

void ProcessJobManager::Emit(ProcessJobEvent event) {
  EventCallback callback;
  {
    std::lock_guard<std::mutex> lock(event_mutex_);
    callback = event_callback_;
  }
  if (callback) callback(event);
}

void ProcessJobManager::CloseAll() {
  std::vector<std::shared_ptr<Entry>> entries;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    entries.reserve(jobs_.size());
    for (const auto& entry : jobs_) entries.push_back(entry.second);
    jobs_.clear();
  }
  for (const auto& entry : entries) CloseEntry(entry, true);
}
