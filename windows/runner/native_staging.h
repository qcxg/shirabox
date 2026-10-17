#ifndef RUNNER_NATIVE_STAGING_H_
#define RUNNER_NATIVE_STAGING_H_

#include <windows.h>

#include <string>
#include <unordered_set>
#include <vector>

struct NativeStagingResult {
  bool success = false;
  std::wstring path;
  std::string message;
  DWORD windows_error = ERROR_SUCCESS;

  static NativeStagingResult Ok(std::wstring value = L"");
  static NativeStagingResult Error(std::string message,
                                   DWORD windows_error = ERROR_SUCCESS);
};

// Owns private, ASCII-only ADB staging directories for this runner process.
// All security-sensitive creation and deletion stays in Win32 so no shell or
// utility process is needed.
class NativeStaging {
 public:
  NativeStaging() = default;
  ~NativeStaging();

  NativeStaging(const NativeStaging&) = delete;
  NativeStaging& operator=(const NativeStaging&) = delete;

  NativeStagingResult Create(const std::string& ascii_prefix);
  NativeStagingResult Delete(const std::string& ascii_path, bool recursive);

 private:
  NativeStagingResult EnsureInitialized();
  NativeStagingResult ValidateParent() const;
  NativeStagingResult VerifyPrivateDirectory(const std::wstring& path) const;
  NativeStagingResult DeleteTreeNoFollow(const std::wstring& path) const;

  std::wstring root_path_;
  std::vector<BYTE> current_user_sid_;
  std::vector<std::vector<BYTE>> allowed_sids_;
  std::unordered_set<std::wstring> owned_paths_;
};

#endif  // RUNNER_NATIVE_STAGING_H_
