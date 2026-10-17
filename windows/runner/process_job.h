#ifndef RUNNER_PROCESS_JOB_H_
#define RUNNER_PROCESS_JOB_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

struct ProcessJobResult {
  bool success = false;
  uint64_t token = 0;
  DWORD process_id = 0;
  std::string message;
  DWORD windows_error = ERROR_SUCCESS;

  static ProcessJobResult Ok(uint64_t token = 0, DWORD process_id = 0);
  static ProcessJobResult Error(std::string message,
                                DWORD windows_error = ERROR_SUCCESS);
};

struct ProcessLaunchRequest {
  std::wstring executable;
  std::vector<std::wstring> arguments;
  std::optional<std::wstring> working_directory;
  bool has_environment = false;
  std::vector<std::pair<std::wstring, std::wstring>> environment;
};

enum class ProcessJobEventKind {
  kStdout,
  kStderr,
  kStdoutClosed,
  kStderrClosed,
  kExit,
  kStreamError,
};

struct ProcessJobEvent {
  uint64_t token = 0;
  ProcessJobEventKind kind = ProcessJobEventKind::kExit;
  std::vector<uint8_t> data;
  DWORD exit_code = 0;
  DWORD windows_error = ERROR_SUCCESS;
  bool is_stderr = false;
};

// Owns per-command Windows Job Objects. Native launches are created suspended,
// assigned to a kill-on-close job, connected to private stdio pipes, and only
// resumed after Dart has subscribed to both output streams.
class ProcessJobManager {
 public:
  using EventCallback = std::function<void(const ProcessJobEvent&)>;

  ProcessJobManager() = default;
  ~ProcessJobManager();

  ProcessJobManager(const ProcessJobManager&) = delete;
  ProcessJobManager& operator=(const ProcessJobManager&) = delete;

  // Legacy attachment for an already-running process. New Windows commands
  // should use Launch followed by Resume to avoid the start/attach interval.
  ProcessJobResult Attach(DWORD process_id);

  ProcessJobResult Launch(const ProcessLaunchRequest& request);
  ProcessJobResult Resume(uint64_t token);
  ProcessJobResult WriteStdin(uint64_t token,
                              const std::vector<uint8_t>& data);
  ProcessJobResult CloseStdin(uint64_t token);
  ProcessJobResult Terminate(uint64_t token, UINT exit_code);
  ProcessJobResult Release(uint64_t token);

  void SetEventCallback(EventCallback callback);
  void CloseAll();

 private:
  struct Entry;

  uint64_t NextTokenLocked();
  std::shared_ptr<Entry> Find(uint64_t token);
  void Emit(ProcessJobEvent event);
  void CloseEntry(const std::shared_ptr<Entry>& entry, bool terminate);

  std::mutex mutex_;
  std::unordered_map<uint64_t, std::shared_ptr<Entry>> jobs_;
  uint64_t next_token_ = 1;

  std::mutex event_mutex_;
  EventCallback event_callback_;
};

#endif  // RUNNER_PROCESS_JOB_H_
