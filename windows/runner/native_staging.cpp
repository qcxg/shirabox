#include "native_staging.h"

#include <Aclapi.h>
#include <bcrypt.h>
#include <knownfolders.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <memory>
#include <utility>

namespace {

constexpr DWORD kDangerousParentRights =
    DELETE | FILE_DELETE_CHILD | WRITE_DAC | WRITE_OWNER;
constexpr BYTE kChildAceFlags = CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE;
constexpr int kCreationAttempts = 16;

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr) {
      CloseHandle(handle_);
    }
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr;
  }

 private:
  HANDLE handle_;
};

struct LocalFreeDeleter {
  void operator()(void* value) const {
    if (value != nullptr) {
      LocalFree(value);
    }
  }
};

using ScopedLocalMemory = std::unique_ptr<void, LocalFreeDeleter>;

struct CoTaskMemDeleter {
  void operator()(void* value) const {
    if (value != nullptr) {
      CoTaskMemFree(value);
    }
  }
};

using ScopedCoTaskMemory = std::unique_ptr<void, CoTaskMemDeleter>;

bool IsAscii(const std::wstring& value) {
  return std::all_of(value.begin(), value.end(),
                     [](wchar_t character) { return character <= 0x7f; });
}

bool IsAsciiPrefix(const std::string& value) {
  if (value.empty() || value.size() > 48) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'A' && character <= 'Z') ||
           (character >= 'a' && character <= 'z') ||
           (character >= '0' && character <= '9') || character == '_' ||
           character == '-';
  });
}

bool IsAsciiDrivePath(const std::wstring& value) {
  return value.size() >= 3 && IsAscii(value) &&
         ((value[0] >= L'A' && value[0] <= L'Z') ||
          (value[0] >= L'a' && value[0] <= L'z')) &&
         value[1] == L':' && (value[2] == L'\\' || value[2] == L'/');
}

std::wstring TrimTrailingSeparators(std::wstring path) {
  while (path.size() > 3 &&
         (path.back() == L'\\' || path.back() == L'/')) {
    path.pop_back();
  }
  return path;
}

std::wstring ExtendedPath(const std::wstring& path) {
  if (path.rfind(L"\\\\?\\", 0) == 0) {
    return path;
  }
  return L"\\\\?\\" + path;
}

std::wstring ComparablePath(std::wstring path) {
  if (path.rfind(L"\\\\?\\", 0) == 0) {
    path.erase(0, 4);
  }
  path = TrimTrailingSeparators(std::move(path));
  std::transform(path.begin(), path.end(), path.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  return path;
}

std::wstring DirectoryName(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"" : path.substr(0, separator);
}

std::wstring FileName(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? path : path.substr(separator + 1);
}

std::wstring WidenAscii(const std::string& value) {
  return std::wstring(value.begin(), value.end());
}

bool EqualSidBytes(const std::vector<BYTE>& left,
                   const std::vector<BYTE>& right) {
  return !left.empty() && !right.empty() &&
         EqualSid(const_cast<BYTE*>(left.data()),
                  const_cast<BYTE*>(right.data())) != FALSE;
}

bool SidEquals(PSID sid, const std::vector<BYTE>& expected) {
  return sid != nullptr && !expected.empty() && IsValidSid(sid) &&
         EqualSid(sid, const_cast<BYTE*>(expected.data())) != FALSE;
}

int AllowedSidIndex(PSID sid,
                    const std::vector<std::vector<BYTE>>& allowed_sids) {
  for (size_t index = 0; index < allowed_sids.size(); ++index) {
    if (SidEquals(sid, allowed_sids[index])) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

NativeStagingResult CurrentUserSid(std::vector<BYTE>* output) {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    return NativeStagingResult::Error("Unable to open the process token.",
                                      GetLastError());
  }
  ScopedHandle token(raw_token);

  DWORD length = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &length);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0) {
    return NativeStagingResult::Error("Unable to size the current user SID.",
                                      GetLastError());
  }
  std::vector<BYTE> token_user(length);
  if (!GetTokenInformation(token.get(), TokenUser, token_user.data(), length,
                           &length)) {
    return NativeStagingResult::Error("Unable to read the current user SID.",
                                      GetLastError());
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(token_user.data());
  const DWORD sid_length = GetLengthSid(user->User.Sid);
  output->resize(sid_length);
  if (!CopySid(sid_length, output->data(), user->User.Sid)) {
    return NativeStagingResult::Error("Unable to copy the current user SID.",
                                      GetLastError());
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult WellKnownSid(WELL_KNOWN_SID_TYPE type,
                                 std::vector<BYTE>* output) {
  DWORD length = SECURITY_MAX_SID_SIZE;
  output->resize(length);
  if (!CreateWellKnownSid(type, nullptr, output->data(), &length)) {
    return NativeStagingResult::Error("Unable to create a required Windows SID.",
                                      GetLastError());
  }
  output->resize(length);
  return NativeStagingResult::Ok();
}

ScopedHandle OpenDirectoryNoFollow(const std::wstring& path,
                                   DWORD desired_access) {
  return ScopedHandle(CreateFileW(
      ExtendedPath(path).c_str(), desired_access,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr));
}

NativeStagingResult VerifyPlainDirectoryHandle(HANDLE handle,
                                               const std::wstring& expected) {
  FILE_ATTRIBUTE_TAG_INFO tag_info{};
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag_info,
                                    sizeof(tag_info))) {
    return NativeStagingResult::Error("Unable to inspect a staging directory.",
                                      GetLastError());
  }
  if ((tag_info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (tag_info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return NativeStagingResult::Error(
        "ADB staging paths must be plain directories.");
  }

  const DWORD required = GetFinalPathNameByHandleW(
      handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (required == 0) {
    return NativeStagingResult::Error(
        "Unable to resolve the staging directory path.", GetLastError());
  }
  std::vector<wchar_t> final_path(required + 1);
  const DWORD written = GetFinalPathNameByHandleW(
      handle, final_path.data(), static_cast<DWORD>(final_path.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= final_path.size()) {
    return NativeStagingResult::Error(
        "Unable to resolve the staging directory path.", GetLastError());
  }
  if (ComparablePath(final_path.data()) != ComparablePath(expected)) {
    return NativeStagingResult::Error(
        "The staging path resolves through an unexpected filesystem object.");
  }
  return NativeStagingResult::Ok();
}

PSID SidFromAllowedAce(ACE_HEADER* header) {
  if (header->AceType == ACCESS_ALLOWED_ACE_TYPE ||
      header->AceType == ACCESS_ALLOWED_CALLBACK_ACE_TYPE) {
    auto* ace = reinterpret_cast<ACCESS_ALLOWED_ACE*>(header);
    return &ace->SidStart;
  }
  if (header->AceType == ACCESS_ALLOWED_OBJECT_ACE_TYPE ||
      header->AceType == ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE) {
    auto* ace = reinterpret_cast<ACCESS_ALLOWED_OBJECT_ACE*>(header);
    BYTE* sid = reinterpret_cast<BYTE*>(&ace->ObjectType);
    if ((ace->Flags & ACE_OBJECT_TYPE_PRESENT) != 0) {
      sid += sizeof(GUID);
    }
    if ((ace->Flags & ACE_INHERITED_OBJECT_TYPE_PRESENT) != 0) {
      sid += sizeof(GUID);
    }
    return sid;
  }
  return nullptr;
}

ACCESS_MASK ExpandedFileMask(ACCESS_MASK mask) {
  GENERIC_MAPPING mapping{FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                          FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  MapGenericMask(&mask, &mapping);
  return mask;
}

NativeStagingResult SecurityForHandle(HANDLE handle,
                                      PSECURITY_DESCRIPTOR* descriptor,
                                      PSID* owner,
                                      PACL* dacl) {
  const DWORD result = GetSecurityInfo(
      handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      owner, nullptr, dacl, nullptr, descriptor);
  if (result != ERROR_SUCCESS) {
    return NativeStagingResult::Error(
        "Unable to read staging filesystem security.", result);
  }
  if (*owner == nullptr || *dacl == nullptr || !IsValidAcl(*dacl)) {
    return NativeStagingResult::Error(
        "The staging filesystem object has invalid security metadata.");
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult RandomSuffix(std::wstring* output) {
  std::array<UCHAR, 16> random_bytes{};
  const NTSTATUS status = BCryptGenRandom(nullptr, random_bytes.data(),
                                         static_cast<ULONG>(random_bytes.size()),
                                         BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if (status < 0) {
    return NativeStagingResult::Error(
        "Windows cryptographic random generation failed.",
        static_cast<DWORD>(status));
  }
  constexpr wchar_t kHex[] = L"0123456789abcdef";
  output->clear();
  output->reserve(random_bytes.size() * 2);
  for (const UCHAR value : random_bytes) {
    output->push_back(kHex[value >> 4]);
    output->push_back(kHex[value & 0x0f]);
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult BuildPrivateSecurity(
    const std::vector<BYTE>& owner_sid,
    const std::vector<std::vector<BYTE>>& allowed_sids,
    std::vector<BYTE>* acl_storage,
    SECURITY_DESCRIPTOR* descriptor) {
  DWORD acl_size = sizeof(ACL);
  for (const auto& sid : allowed_sids) {
    acl_size += sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) +
                GetLengthSid(const_cast<BYTE*>(sid.data()));
  }
  acl_storage->resize(acl_size);
  auto* acl = reinterpret_cast<PACL>(acl_storage->data());
  if (!InitializeAcl(acl, acl_size, ACL_REVISION)) {
    return NativeStagingResult::Error("Unable to initialize the staging ACL.",
                                      GetLastError());
  }
  for (const auto& sid : allowed_sids) {
    if (!AddAccessAllowedAceEx(acl, ACL_REVISION, kChildAceFlags,
                               FILE_ALL_ACCESS,
                               const_cast<BYTE*>(sid.data()))) {
      return NativeStagingResult::Error("Unable to build the staging ACL.",
                                        GetLastError());
    }
  }

  if (!InitializeSecurityDescriptor(descriptor,
                                    SECURITY_DESCRIPTOR_REVISION) ||
      !SetSecurityDescriptorOwner(
          descriptor, const_cast<BYTE*>(owner_sid.data()), FALSE) ||
      !SetSecurityDescriptorDacl(descriptor, TRUE, acl, FALSE) ||
      !SetSecurityDescriptorControl(descriptor, SE_DACL_PROTECTED,
                                    SE_DACL_PROTECTED)) {
    return NativeStagingResult::Error(
        "Unable to build the staging security descriptor.", GetLastError());
  }
  return NativeStagingResult::Ok();
}

bool IsDotEntry(const wchar_t* name) {
  return wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0;
}

NativeStagingResult DeleteEntryNoFollow(const std::wstring& path,
                                        DWORD attributes);

NativeStagingResult DeleteDirectoryContents(const std::wstring& path) {
  WIN32_FIND_DATAW data{};
  const std::wstring pattern = ExtendedPath(path + L"\\*");
  HANDLE raw_find = FindFirstFileW(pattern.c_str(), &data);
  if (raw_find == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND) {
      return NativeStagingResult::Ok();
    }
    return NativeStagingResult::Error(
        "Unable to enumerate the ADB staging directory.", error);
  }

  NativeStagingResult result = NativeStagingResult::Ok();
  do {
    if (IsDotEntry(data.cFileName)) {
      continue;
    }
    result = DeleteEntryNoFollow(path + L"\\" + data.cFileName,
                                 data.dwFileAttributes);
    if (!result.success) {
      break;
    }
  } while (FindNextFileW(raw_find, &data));
  const DWORD enumeration_error = GetLastError();
  FindClose(raw_find);
  if (result.success && enumeration_error != ERROR_NO_MORE_FILES) {
    return NativeStagingResult::Error(
        "Unable to finish enumerating the ADB staging directory.",
        enumeration_error);
  }
  return result;
}

NativeStagingResult DeleteEntryNoFollow(const std::wstring& path,
                                        DWORD attributes) {
  const bool is_directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  const bool is_reparse = (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
  if (is_directory && !is_reparse) {
    const DWORD current_attributes = GetFileAttributesW(ExtendedPath(path).c_str());
    if (current_attributes == INVALID_FILE_ATTRIBUTES) {
      const DWORD error = GetLastError();
      if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
        return NativeStagingResult::Ok();
      }
      return NativeStagingResult::Error(
          "Unable to inspect an ADB staging child directory.", error);
    }
    if ((current_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      if (!RemoveDirectoryW(ExtendedPath(path).c_str())) {
        return NativeStagingResult::Error(
            "Unable to remove a staging directory reparse point.",
            GetLastError());
      }
      return NativeStagingResult::Ok();
    }
    NativeStagingResult result = DeleteDirectoryContents(path);
    if (!result.success) {
      return result;
    }
    if (!RemoveDirectoryW(ExtendedPath(path).c_str())) {
      return NativeStagingResult::Error(
          "Unable to remove a staging child directory.", GetLastError());
    }
    return NativeStagingResult::Ok();
  }

  if ((attributes & FILE_ATTRIBUTE_READONLY) != 0) {
    SetFileAttributesW(ExtendedPath(path).c_str(),
                       attributes & ~FILE_ATTRIBUTE_READONLY);
  }
  const BOOL deleted = is_directory
                           ? RemoveDirectoryW(ExtendedPath(path).c_str())
                           : DeleteFileW(ExtendedPath(path).c_str());
  if (!deleted) {
    return NativeStagingResult::Error(
        "Unable to remove an ADB staging entry.", GetLastError());
  }
  return NativeStagingResult::Ok();
}

}  // namespace

NativeStagingResult NativeStagingResult::Ok(std::wstring value) {
  NativeStagingResult result;
  result.success = true;
  result.path = std::move(value);
  return result;
}

NativeStagingResult NativeStagingResult::Error(std::string message,
                                               DWORD windows_error) {
  NativeStagingResult result;
  result.message = std::move(message);
  result.windows_error = windows_error;
  return result;
}

NativeStaging::~NativeStaging() {
  const std::vector<std::wstring> paths(owned_paths_.begin(),
                                        owned_paths_.end());
  for (const auto& comparable_path : paths) {
    // The owned set stores comparable paths, which remain valid ASCII paths.
    const auto verification = VerifyPrivateDirectory(comparable_path);
    if (verification.success) {
      DeleteTreeNoFollow(comparable_path);
    }
  }
}

NativeStagingResult NativeStaging::EnsureInitialized() {
  if (!root_path_.empty()) {
    return NativeStagingResult::Ok();
  }

  PWSTR raw_program_data = nullptr;
  const HRESULT known_folder_result = SHGetKnownFolderPath(
      FOLDERID_ProgramData, KF_FLAG_DEFAULT, nullptr, &raw_program_data);
  ScopedCoTaskMemory program_data(raw_program_data);
  if (FAILED(known_folder_result) || raw_program_data == nullptr) {
    return NativeStagingResult::Error(
        "Windows did not provide the ProgramData directory.",
        static_cast<DWORD>(known_folder_result));
  }
  root_path_ = TrimTrailingSeparators(raw_program_data);
  if (!IsAsciiDrivePath(root_path_)) {
    root_path_.clear();
    return NativeStagingResult::Error(
        "ProgramData is not an ASCII local drive path.");
  }
  const std::wstring drive_root = root_path_.substr(0, 3);
  if (GetDriveTypeW(drive_root.c_str()) == DRIVE_REMOTE) {
    root_path_.clear();
    return NativeStagingResult::Error(
        "ProgramData on a remote drive cannot be used for ADB staging.");
  }

  NativeStagingResult result = CurrentUserSid(&current_user_sid_);
  if (!result.success) {
    root_path_.clear();
    return result;
  }

  allowed_sids_.push_back(current_user_sid_);
  for (const WELL_KNOWN_SID_TYPE type : {WinLocalSystemSid,
                                         WinBuiltinAdministratorsSid}) {
    std::vector<BYTE> sid;
    result = WellKnownSid(type, &sid);
    if (!result.success) {
      root_path_.clear();
      allowed_sids_.clear();
      return result;
    }
    const bool duplicate = std::any_of(
        allowed_sids_.begin(), allowed_sids_.end(),
        [&sid](const std::vector<BYTE>& existing) {
          return EqualSidBytes(existing, sid);
        });
    if (!duplicate) {
      allowed_sids_.push_back(std::move(sid));
    }
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult NativeStaging::ValidateParent() const {
  ScopedHandle handle =
      OpenDirectoryNoFollow(root_path_, READ_CONTROL | FILE_READ_ATTRIBUTES);
  if (!handle.valid()) {
    return NativeStagingResult::Error(
        "Unable to open the ProgramData staging parent.", GetLastError());
  }
  NativeStagingResult result = VerifyPlainDirectoryHandle(handle.get(), root_path_);
  if (!result.success) {
    return result;
  }

  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PSID owner = nullptr;
  PACL dacl = nullptr;
  result = SecurityForHandle(handle.get(), &raw_descriptor, &owner, &dacl);
  ScopedLocalMemory descriptor(raw_descriptor);
  if (!result.success) {
    return result;
  }
  if (AllowedSidIndex(owner, allowed_sids_) < 0) {
    return NativeStagingResult::Error(
        "The ProgramData staging parent has an untrusted owner.");
  }

  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace)) {
      return NativeStagingResult::Error(
          "Unable to inspect the ProgramData ACL.", GetLastError());
    }
    auto* header = static_cast<ACE_HEADER*>(raw_ace);
    if ((header->AceFlags & INHERIT_ONLY_ACE) != 0) {
      continue;
    }
    if (header->AceType == ACCESS_ALLOWED_COMPOUND_ACE_TYPE) {
      return NativeStagingResult::Error(
          "The ProgramData staging parent has an unsupported allow entry.");
    }
    PSID sid = SidFromAllowedAce(header);
    if (sid == nullptr) {
      continue;
    }
    auto* allowed_ace = reinterpret_cast<ACCESS_ALLOWED_ACE*>(header);
    const ACCESS_MASK permissions = ExpandedFileMask(allowed_ace->Mask);
    if (AllowedSidIndex(sid, allowed_sids_) < 0 &&
        (permissions & kDangerousParentRights) != 0) {
      return NativeStagingResult::Error(
          "The ProgramData staging parent grants unsafe replacement rights.");
    }
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult NativeStaging::VerifyPrivateDirectory(
    const std::wstring& path) const {
  ScopedHandle handle =
      OpenDirectoryNoFollow(path, READ_CONTROL | FILE_READ_ATTRIBUTES);
  if (!handle.valid()) {
    return NativeStagingResult::Error(
        "Unable to open the private ADB staging directory.", GetLastError());
  }
  NativeStagingResult result = VerifyPlainDirectoryHandle(handle.get(), path);
  if (!result.success) {
    return result;
  }

  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PSID owner = nullptr;
  PACL dacl = nullptr;
  result = SecurityForHandle(handle.get(), &raw_descriptor, &owner, &dacl);
  ScopedLocalMemory descriptor(raw_descriptor);
  if (!result.success) {
    return result;
  }
  if (!SidEquals(owner, current_user_sid_)) {
    return NativeStagingResult::Error(
        "The private ADB staging directory has an unexpected owner.");
  }

  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    return NativeStagingResult::Error(
        "The private ADB staging DACL is not protected.", GetLastError());
  }
  if (dacl->AceCount != allowed_sids_.size()) {
    return NativeStagingResult::Error(
        "The private ADB staging ACL has unexpected entries.");
  }

  std::vector<bool> seen(allowed_sids_.size(), false);
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace)) {
      return NativeStagingResult::Error(
          "Unable to inspect the private ADB staging ACL.", GetLastError());
    }
    auto* header = static_cast<ACE_HEADER*>(raw_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE ||
        (header->AceFlags & INHERITED_ACE) != 0 ||
        (header->AceFlags & kChildAceFlags) != kChildAceFlags) {
      return NativeStagingResult::Error(
          "The private ADB staging ACL has an unsafe entry.");
    }
    auto* ace = reinterpret_cast<ACCESS_ALLOWED_ACE*>(header);
    const int allowed_index = AllowedSidIndex(&ace->SidStart, allowed_sids_);
    if (allowed_index < 0 || seen[allowed_index] ||
        (ExpandedFileMask(ace->Mask) & FILE_ALL_ACCESS) != FILE_ALL_ACCESS) {
      return NativeStagingResult::Error(
          "The private ADB staging ACL has an unexpected entry.");
    }
    seen[allowed_index] = true;
  }
  return NativeStagingResult::Ok();
}

NativeStagingResult NativeStaging::Create(const std::string& ascii_prefix) {
  if (!IsAsciiPrefix(ascii_prefix)) {
    return NativeStagingResult::Error(
        "The staging prefix must contain 1-48 ASCII letters, digits, '_' or '-'.");
  }
  NativeStagingResult result = EnsureInitialized();
  if (!result.success) {
    return result;
  }
  result = ValidateParent();
  if (!result.success) {
    return result;
  }

  std::vector<BYTE> acl_storage;
  SECURITY_DESCRIPTOR descriptor{};
  result = BuildPrivateSecurity(current_user_sid_, allowed_sids_, &acl_storage,
                                &descriptor);
  if (!result.success) {
    return result;
  }
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = &descriptor;
  attributes.bInheritHandle = FALSE;

  for (int attempt = 0; attempt < kCreationAttempts; ++attempt) {
    std::wstring suffix;
    result = RandomSuffix(&suffix);
    if (!result.success) {
      return result;
    }
    const std::wstring path =
        root_path_ + L"\\" + WidenAscii(ascii_prefix) + suffix;
    if (!CreateDirectoryW(ExtendedPath(path).c_str(), &attributes)) {
      const DWORD error = GetLastError();
      if (error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS) {
        continue;
      }
      return NativeStagingResult::Error(
          "Windows rejected the private ADB staging directory.", error);
    }

    result = VerifyPrivateDirectory(path);
    if (!result.success) {
      RemoveDirectoryW(ExtendedPath(path).c_str());
      return result;
    }
    owned_paths_.insert(ComparablePath(path));
    return NativeStagingResult::Ok(path);
  }
  return NativeStagingResult::Error(
      "Unable to reserve a unique private ADB staging directory.");
}

NativeStagingResult NativeStaging::Delete(const std::string& ascii_path,
                                          bool recursive) {
  if (ascii_path.empty() ||
      !std::all_of(ascii_path.begin(), ascii_path.end(),
                   [](unsigned char value) { return value <= 0x7f; })) {
    return NativeStagingResult::Error("The ADB staging path is invalid.");
  }
  NativeStagingResult result = EnsureInitialized();
  if (!result.success) {
    return result;
  }

  const std::wstring path = WidenAscii(ascii_path);
  const std::wstring comparable_path = ComparablePath(path);
  if (owned_paths_.find(comparable_path) == owned_paths_.end() ||
      ComparablePath(DirectoryName(path)) != ComparablePath(root_path_) ||
      FileName(path).empty()) {
    return NativeStagingResult::Error(
        "The runner does not own this ADB staging directory.");
  }

  const DWORD attributes = GetFileAttributesW(ExtendedPath(path).c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
      owned_paths_.erase(comparable_path);
      return NativeStagingResult::Ok();
    }
    return NativeStagingResult::Error(
        "Unable to inspect the ADB staging directory before cleanup.", error);
  }
  result = VerifyPrivateDirectory(path);
  if (!result.success) {
    return result;
  }

  if (recursive) {
    result = DeleteTreeNoFollow(path);
  } else if (!RemoveDirectoryW(ExtendedPath(path).c_str())) {
    result = NativeStagingResult::Error(
        "Unable to remove the ADB staging directory.", GetLastError());
  } else {
    result = NativeStagingResult::Ok();
  }
  if (result.success) {
    owned_paths_.erase(comparable_path);
  }
  return result;
}

NativeStagingResult NativeStaging::DeleteTreeNoFollow(
    const std::wstring& path) const {
  NativeStagingResult result = DeleteDirectoryContents(path);
  if (!result.success) {
    return result;
  }
  if (!RemoveDirectoryW(ExtendedPath(path).c_str())) {
    return NativeStagingResult::Error(
        "Unable to remove the ADB staging directory.", GetLastError());
  }
  return NativeStagingResult::Ok();
}
