#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "win32_window.h"
#include "native_staging.h"
#include "process_job.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void StartNativeStagingWorker();
  void StopNativeStagingWorker();
  bool EnqueueNativeStagingTask(std::function<void()> task);
  void SendProcessEvent(const ProcessJobEvent& event);
  void FlushProcessEvents();
  bool HasProcessEventSink();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  NativeStaging native_staging_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_staging_channel_;
  std::mutex native_staging_tasks_mutex_;
  std::condition_variable native_staging_tasks_changed_;
  std::deque<std::function<void()>> native_staging_tasks_;
  std::thread native_staging_worker_;
  bool native_staging_stopping_ = false;

  ProcessJobManager process_jobs_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      process_job_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      process_event_channel_;
  std::mutex process_event_sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      process_event_sink_;
  std::mutex process_events_mutex_;
  std::deque<ProcessJobEvent> process_events_;
  std::unordered_map<uint64_t, size_t> pending_stdout_bytes_;
  std::unordered_map<uint64_t, size_t> pending_stderr_bytes_;
  bool process_event_message_posted_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
