#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <exception>
#include <limits>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr UINT kProcessEventMessage = WM_APP + 0x51;
constexpr size_t kMaxPendingProcessStreamBytes = 1024 * 1024;

std::optional<int64_t> ReadInteger(const flutter::EncodableMap& arguments,
                                   const char* name) {
  const auto entry = arguments.find(flutter::EncodableValue(name));
  if (entry == arguments.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&entry->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&entry->second)) {
    return *value;
  }
  return std::nullopt;
}

std::optional<std::string> ReadString(
    const flutter::EncodableMap& arguments,
    const char* name) {
  const auto entry = arguments.find(flutter::EncodableValue(name));
  if (entry == arguments.end()) return std::nullopt;
  if (const auto* value = std::get_if<std::string>(&entry->second)) {
    return *value;
  }
  return std::nullopt;
}

std::optional<std::wstring> Utf16FromUtf8(const std::string& input) {
  if (input.empty()) return std::wstring();
  if (input.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::nullopt;
  }
  const int source_length = static_cast<int>(input.size());
  const int target_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), source_length, nullptr, 0);
  if (target_length <= 0) return std::nullopt;
  std::wstring output(static_cast<size_t>(target_length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                          source_length, output.data(), target_length) !=
      target_length) {
    return std::nullopt;
  }
  return output;
}

const char* ProcessEventName(ProcessJobEventKind kind) {
  switch (kind) {
    case ProcessJobEventKind::kStdout:
      return "stdout";
    case ProcessJobEventKind::kStderr:
      return "stderr";
    case ProcessJobEventKind::kStdoutClosed:
      return "stdoutClosed";
    case ProcessJobEventKind::kStderrClosed:
      return "stderrClosed";
    case ProcessJobEventKind::kExit:
      return "exit";
    case ProcessJobEventKind::kStreamError:
      return "streamError";
  }
  return "unknown";
}

void ReturnProcessJobError(
    const ProcessJobResult& process_result,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  result->Error(
      "process_job_error", process_result.message,
      flutter::EncodableValue(
          static_cast<int64_t>(process_result.windows_error)));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { StopNativeStagingWorker(); }

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  StartNativeStagingWorker();
  native_staging_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "shirabox/native_staging",
          &flutter::StandardMethodCodec::GetInstance());
  native_staging_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Expected a map of arguments.");
          return;
        }

        if (call.method_name() == "createAdbStagingDirectory") {
          const auto prefix_entry =
              arguments->find(flutter::EncodableValue("prefix"));
          if (prefix_entry == arguments->end() ||
              !std::holds_alternative<std::string>(prefix_entry->second)) {
            result->Error("invalid_arguments", "Missing ASCII prefix.");
            return;
          }
          const std::string prefix = std::get<std::string>(prefix_entry->second);
          auto shared_result =
              std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                  std::move(result));
          if (!EnqueueNativeStagingTask([this, prefix, shared_result]() {
                try {
                  const NativeStagingResult native_result =
                      native_staging_.Create(prefix);
                  if (!native_result.success) {
                    shared_result->Error(
                        "native_staging_error", native_result.message,
                        flutter::EncodableValue(static_cast<int64_t>(
                            native_result.windows_error)));
                    return;
                  }
                  shared_result->Success(flutter::EncodableValue(
                      Utf8FromUtf16(native_result.path.c_str())));
                } catch (const std::exception& error) {
                  shared_result->Error(
                      "native_staging_exception", error.what());
                } catch (...) {
                  shared_result->Error("native_staging_exception",
                                       "Native staging failed unexpectedly.");
                }
              })) {
            shared_result->Error("native_staging_shutdown",
                                 "The native staging worker is stopping.");
          }
          return;
        }

        if (call.method_name() == "deleteAdbStagingDirectory") {
          const auto path_entry =
              arguments->find(flutter::EncodableValue("path"));
          const auto recursive_entry =
              arguments->find(flutter::EncodableValue("recursive"));
          if (path_entry == arguments->end() ||
              recursive_entry == arguments->end() ||
              !std::holds_alternative<std::string>(path_entry->second) ||
              !std::holds_alternative<bool>(recursive_entry->second)) {
            result->Error("invalid_arguments", "Missing cleanup arguments.");
            return;
          }
          const std::string path = std::get<std::string>(path_entry->second);
          const bool recursive = std::get<bool>(recursive_entry->second);
          auto shared_result =
              std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                  std::move(result));
          if (!EnqueueNativeStagingTask(
                  [this, path, recursive, shared_result]() {
                    try {
                      const NativeStagingResult native_result =
                          native_staging_.Delete(path, recursive);
                      if (!native_result.success) {
                        shared_result->Error(
                            "native_staging_error", native_result.message,
                            flutter::EncodableValue(static_cast<int64_t>(
                                native_result.windows_error)));
                        return;
                      }
                      shared_result->Success();
                    } catch (const std::exception& error) {
                      shared_result->Error(
                          "native_staging_exception", error.what());
                    } catch (...) {
                      shared_result->Error(
                          "native_staging_exception",
                          "Native staging cleanup failed unexpectedly.");
                    }
                  })) {
            shared_result->Error("native_staging_shutdown",
                                 "The native staging worker is stopping.");
          }
          return;
        }

        result->NotImplemented();
      });

  process_jobs_.SetEventCallback(
      [this](const ProcessJobEvent& event) { SendProcessEvent(event); });
  process_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "shirabox/process_events",
          &flutter::StandardMethodCodec::GetInstance());
  process_event_channel_->SetStreamHandler(
      std::make_unique<
          flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<
                     flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(process_event_sink_mutex_);
            process_event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(process_event_sink_mutex_);
            process_event_sink_.reset();
            return nullptr;
          }));

  process_job_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "shirabox/process_job",
          &flutter::StandardMethodCodec::GetInstance());
  process_job_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Expected a map of arguments.");
          return;
        }

        if (call.method_name() == "processEventsReady") {
          result->Success(flutter::EncodableValue(HasProcessEventSink()));
          return;
        }

        if (call.method_name() == "launchOwnedProcess") {
          const auto executable_utf8 = ReadString(*arguments, "executable");
          const auto arguments_entry =
              arguments->find(flutter::EncodableValue("arguments"));
          if (!executable_utf8.has_value() ||
              arguments_entry == arguments->end() ||
              !std::holds_alternative<flutter::EncodableList>(
                  arguments_entry->second)) {
            result->Error("invalid_arguments",
                          "Missing executable or argument list.");
            return;
          }

          ProcessLaunchRequest request;
          const auto executable = Utf16FromUtf8(executable_utf8.value());
          if (!executable.has_value()) {
            result->Error("invalid_arguments",
                          "The executable is not valid UTF-8.");
            return;
          }
          request.executable = executable.value();

          const auto& encoded_arguments =
              std::get<flutter::EncodableList>(arguments_entry->second);
          request.arguments.reserve(encoded_arguments.size());
          for (const auto& encoded : encoded_arguments) {
            const auto* value = std::get_if<std::string>(&encoded);
            if (value == nullptr) {
              result->Error("invalid_arguments",
                            "Every process argument must be a string.");
              return;
            }
            const auto converted = Utf16FromUtf8(*value);
            if (!converted.has_value()) {
              result->Error("invalid_arguments",
                            "A process argument is not valid UTF-8.");
              return;
            }
            request.arguments.push_back(converted.value());
          }

          const auto working_entry =
              arguments->find(flutter::EncodableValue("workingDirectory"));
          if (working_entry != arguments->end()) {
            const auto* value =
                std::get_if<std::string>(&working_entry->second);
            if (value == nullptr) {
              result->Error("invalid_arguments",
                            "The working directory must be a string.");
              return;
            }
            const auto converted = Utf16FromUtf8(*value);
            if (!converted.has_value()) {
              result->Error("invalid_arguments",
                            "The working directory is not valid UTF-8.");
              return;
            }
            request.working_directory = converted.value();
          }

          const auto environment_entry =
              arguments->find(flutter::EncodableValue("environment"));
          if (environment_entry != arguments->end()) {
            if (!std::holds_alternative<flutter::EncodableMap>(
                    environment_entry->second)) {
              result->Error("invalid_arguments",
                            "The process environment must be a string map.");
              return;
            }
            request.has_environment = true;
            const auto& environment =
                std::get<flutter::EncodableMap>(environment_entry->second);
            request.environment.reserve(environment.size());
            for (const auto& encoded : environment) {
              const auto* key = std::get_if<std::string>(&encoded.first);
              const auto* value = std::get_if<std::string>(&encoded.second);
              if (key == nullptr || value == nullptr) {
                result->Error("invalid_arguments",
                              "The process environment must be a string map.");
                return;
              }
              const auto converted_key = Utf16FromUtf8(*key);
              const auto converted_value = Utf16FromUtf8(*value);
              if (!converted_key.has_value() ||
                  !converted_value.has_value()) {
                result->Error("invalid_arguments",
                              "The process environment is not valid UTF-8.");
                return;
              }
              request.environment.emplace_back(converted_key.value(),
                                               converted_value.value());
            }
          }

          const ProcessJobResult process_result =
              process_jobs_.Launch(request);
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("token"),
               flutter::EncodableValue(
                   static_cast<int64_t>(process_result.token))},
              {flutter::EncodableValue("pid"),
               flutter::EncodableValue(
                   static_cast<int64_t>(process_result.process_id))},
          }));
          return;
        }

        if (call.method_name() == "resumeOwnedProcess") {
          const auto token = ReadInteger(*arguments, "token");
          if (!token.has_value() || token.value() <= 0) {
            result->Error("invalid_arguments", "Invalid process job token.");
            return;
          }
          if (!HasProcessEventSink()) {
            result->Error("process_events_unavailable",
                          "The native process event stream is not listening.");
            return;
          }
          const ProcessJobResult process_result =
              process_jobs_.Resume(static_cast<uint64_t>(token.value()));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "writeProcessStdin") {
          const auto token = ReadInteger(*arguments, "token");
          const auto data_entry =
              arguments->find(flutter::EncodableValue("data"));
          if (!token.has_value() || token.value() <= 0 ||
              data_entry == arguments->end() ||
              !std::holds_alternative<std::vector<uint8_t>>(
                  data_entry->second)) {
            result->Error("invalid_arguments",
                          "Invalid process stdin arguments.");
            return;
          }
          const ProcessJobResult process_result = process_jobs_.WriteStdin(
              static_cast<uint64_t>(token.value()),
              std::get<std::vector<uint8_t>>(data_entry->second));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "closeProcessStdin") {
          const auto token = ReadInteger(*arguments, "token");
          if (!token.has_value() || token.value() <= 0) {
            result->Error("invalid_arguments", "Invalid process job token.");
            return;
          }
          const ProcessJobResult process_result =
              process_jobs_.CloseStdin(static_cast<uint64_t>(token.value()));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "attachProcess") {
          const auto process_id = ReadInteger(*arguments, "pid");
          if (!process_id.has_value() || process_id.value() <= 0 ||
              process_id.value() > std::numeric_limits<DWORD>::max()) {
            result->Error("invalid_arguments", "Invalid process ID.");
            return;
          }
          const ProcessJobResult process_result =
              process_jobs_.Attach(static_cast<DWORD>(process_id.value()));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("token"),
               flutter::EncodableValue(
                   static_cast<int64_t>(process_result.token))},
          }));
          return;
        }

        if (call.method_name() == "terminateProcessJob") {
          const auto token = ReadInteger(*arguments, "token");
          const auto exit_code = ReadInteger(*arguments, "exitCode");
          if (!token.has_value() || token.value() <= 0 ||
              !exit_code.has_value() || exit_code.value() < 0 ||
              exit_code.value() > std::numeric_limits<UINT>::max()) {
            result->Error("invalid_arguments",
                          "Invalid process job termination arguments.");
            return;
          }
          const ProcessJobResult process_result = process_jobs_.Terminate(
              static_cast<uint64_t>(token.value()),
              static_cast<UINT>(exit_code.value()));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "releaseProcessJob") {
          const auto token = ReadInteger(*arguments, "token");
          if (!token.has_value() || token.value() <= 0) {
            result->Error("invalid_arguments", "Invalid process job token.");
            return;
          }
          const ProcessJobResult process_result =
              process_jobs_.Release(static_cast<uint64_t>(token.value()));
          if (!process_result.success) {
            ReturnProcessJobError(process_result, result);
            return;
          }
          result->Success();
          return;
        }

        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  //flutter_controller_->engine()->SetNextFrameCallback([&]() {
   // this->Show();
 /// });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  StopNativeStagingWorker();
  process_jobs_.CloseAll();
  process_jobs_.SetEventCallback({});
  if (process_event_channel_) {
    process_event_channel_->SetStreamHandler(nullptr);
  }
  {
    std::lock_guard<std::mutex> lock(process_event_sink_mutex_);
    process_event_sink_.reset();
  }
  {
    std::lock_guard<std::mutex> lock(process_events_mutex_);
    process_events_.clear();
    pending_stdout_bytes_.clear();
    pending_stderr_bytes_.clear();
    process_event_message_posted_ = false;
  }
  native_staging_channel_.reset();
  process_job_channel_.reset();
  process_event_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SendProcessEvent(const ProcessJobEvent& event) {
  bool should_post = false;
  {
    std::lock_guard<std::mutex> lock(process_events_mutex_);
    if (event.kind == ProcessJobEventKind::kStdout ||
        event.kind == ProcessJobEventKind::kStderr) {
      auto& pending_by_token = event.kind == ProcessJobEventKind::kStdout
                                   ? pending_stdout_bytes_
                                   : pending_stderr_bytes_;
      size_t& pending = pending_by_token[event.token];
      while (pending + event.data.size() >
             kMaxPendingProcessStreamBytes) {
        const auto oldest = std::find_if(
            process_events_.begin(), process_events_.end(),
            [&event](const ProcessJobEvent& queued) {
              return queued.token == event.token && queued.kind == event.kind;
            });
        if (oldest == process_events_.end()) break;
        pending -= std::min(pending, oldest->data.size());
        process_events_.erase(oldest);
      }
      pending += event.data.size();
    }
    process_events_.push_back(event);
    if (!process_event_message_posted_) {
      process_event_message_posted_ = true;
      should_post = true;
    }
  }
  if (should_post) {
    PostMessage(GetHandle(), kProcessEventMessage, 0, 0);
  }
}

void FlutterWindow::FlushProcessEvents() {
  std::deque<ProcessJobEvent> events;
  {
    std::lock_guard<std::mutex> lock(process_events_mutex_);
    events.swap(process_events_);
    pending_stdout_bytes_.clear();
    pending_stderr_bytes_.clear();
    process_event_message_posted_ = false;
  }

  std::lock_guard<std::mutex> sink_lock(process_event_sink_mutex_);
  if (!process_event_sink_) return;
  for (const auto& event : events) {
    flutter::EncodableMap value{
        {flutter::EncodableValue("token"),
         flutter::EncodableValue(static_cast<int64_t>(event.token))},
        {flutter::EncodableValue("type"),
         flutter::EncodableValue(ProcessEventName(event.kind))},
    };
    if (!event.data.empty()) {
      value.emplace(flutter::EncodableValue("data"),
                    flutter::EncodableValue(event.data));
    }
    if (event.kind == ProcessJobEventKind::kExit) {
      value.emplace(flutter::EncodableValue("exitCode"),
                    flutter::EncodableValue(
                        static_cast<int64_t>(event.exit_code)));
    }
    if (event.kind == ProcessJobEventKind::kStreamError) {
      value.emplace(flutter::EncodableValue("windowsError"),
                    flutter::EncodableValue(
                        static_cast<int64_t>(event.windows_error)));
      value.emplace(flutter::EncodableValue("stream"),
                    flutter::EncodableValue(event.is_stderr ? "stderr"
                                                            : "stdout"));
    }
    process_event_sink_->Success(flutter::EncodableValue(std::move(value)));
  }
}

bool FlutterWindow::HasProcessEventSink() {
  std::lock_guard<std::mutex> lock(process_event_sink_mutex_);
  return process_event_sink_ != nullptr;
}

void FlutterWindow::StartNativeStagingWorker() {
  native_staging_stopping_ = false;
  native_staging_worker_ = std::thread([this]() {
    while (true) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(native_staging_tasks_mutex_);
        native_staging_tasks_changed_.wait(lock, [this]() {
          return native_staging_stopping_ || !native_staging_tasks_.empty();
        });
        if (native_staging_stopping_ && native_staging_tasks_.empty()) {
          return;
        }
        task = std::move(native_staging_tasks_.front());
        native_staging_tasks_.pop_front();
      }
      task();
    }
  });
}

void FlutterWindow::StopNativeStagingWorker() {
  {
    std::lock_guard<std::mutex> lock(native_staging_tasks_mutex_);
    native_staging_stopping_ = true;
  }
  native_staging_tasks_changed_.notify_all();
  if (native_staging_worker_.joinable()) {
    native_staging_worker_.join();
  }
}

bool FlutterWindow::EnqueueNativeStagingTask(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(native_staging_tasks_mutex_);
    if (native_staging_stopping_) {
      return false;
    }
    native_staging_tasks_.push_back(std::move(task));
  }
  native_staging_tasks_changed_.notify_one();
  return true;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kProcessEventMessage) {
    FlushProcessEvents();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
