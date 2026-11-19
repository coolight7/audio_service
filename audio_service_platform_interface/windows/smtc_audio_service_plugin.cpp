#include "include/audio_service_platform_interface/smtc_audio_service_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <utility>

#include "smtc_service.h"

namespace {

// channel 名与 Dart 侧 lib/smtc_audio_service.dart 里的常量保持一致
constexpr char kChannelName[] = "audio_service/smtc";

// 排查用：把 SMTC 各步的结果追加到 %TEMP%\musicxx_smtc.log
// （媒体面板不出现时，先看这里能区分「控件没建成」与「系统没显示」）
// 文件超过 64 KB 时重写一份，避免一直跑下去越攒越大
void AppendSmtcLog(const std::string& line) {
  wchar_t temp[MAX_PATH] = {};
  const DWORD length = ::GetTempPathW(MAX_PATH, temp);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }
  const std::wstring path = std::wstring(temp) + L"musicxx_smtc.log";
  DWORD creation = OPEN_ALWAYS;
  WIN32_FILE_ATTRIBUTE_DATA attributes = {};
  if (::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes) &&
      attributes.nFileSizeHigh == 0 && attributes.nFileSizeLow > 64 * 1024) {
    creation = CREATE_ALWAYS;
  }
  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                              nullptr, creation, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const std::string text = line + "\n";
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                        static_cast<int>(value.size()), result.data(), size,
                        nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                        result.data(), size);
  return result;
}

const flutter::EncodableValue* FindValue(const flutter::EncodableMap& map,
                                         const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring GetString(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return std::wstring();
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::wstring() : Utf8ToWide(*text);
}

bool GetBool(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

int64_t GetInt(const flutter::EncodableMap& map, const char* key,
               int64_t fallback) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  return fallback;
}

std::wstring WindowClassOf(HWND hwnd) {
  wchar_t name[128] = {};
  if (hwnd == nullptr || ::GetClassNameW(hwnd, name, 128) == 0) {
    return std::wstring();
  }
  return std::wstring(name);
}

struct FindHostWindowContext {
  // 优先用可见窗口；都没显示时（开机就最小化到托盘）也要有一个可用的
  HWND visible = nullptr;
  HWND hidden = nullptr;
};

// 找本进程的顶层主窗口：
// * 插件注册时 registrar->GetView() 给的是 Flutter 的 view 窗口（类名
//   FLUTTERVIEW，是主窗口的子窗口），拿它调 GetForWindow 会返回 E_INVALIDARG；
// * 主窗口是 WS_OVERLAPPEDWINDOW，启动动画是 WS_POPUP，靠样式区分。
BOOL CALLBACK FindTopLevelWindowEnum(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<FindHostWindowContext*>(lparam);
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(hwnd, &process_id);
  if (process_id != ::GetCurrentProcessId()) {
    return TRUE;
  }
  const LONG style = ::GetWindowLongW(hwnd, GWL_STYLE);
  if ((style & WS_OVERLAPPEDWINDOW) != WS_OVERLAPPEDWINDOW) {
    return TRUE;
  }
  if (::GetWindow(hwnd, GW_OWNER) != nullptr) {
    return TRUE;
  }
  if (::IsWindowVisible(hwnd) != FALSE) {
    context->visible = hwnd;
    return FALSE;
  }
  if (context->hidden == nullptr) {
    context->hidden = hwnd;
  }
  return TRUE;
}

// Flutter 的 view 窗口是主窗口的子窗口，往上找就能拿到主窗口，
// 不依赖窗口标题或类名；拿不到时（嵌入方式变了）退回按样式找顶层窗口
HWND ResolveHostWindow(HWND view_window) {
  if (view_window != nullptr && ::IsWindow(view_window)) {
    const HWND root = ::GetAncestor(view_window, GA_ROOT);
    if (root != nullptr && root != view_window &&
        ::GetWindow(root, GW_OWNER) == nullptr) {
      return root;
    }
  }
  FindHostWindowContext context;
  ::EnumWindows(&FindTopLevelWindowEnum, reinterpret_cast<LPARAM>(&context));
  return context.visible != nullptr ? context.visible : context.hidden;
}

// 插件的进程级状态：channel、方法回调、日志状态和 SMTC 服务都在这里。
//
// 这份状态只创建一次，**故意不销毁**：插件随引擎析构（`FlutterViewControllerDestroy`）
// 被销毁，那时再去摘方法回调（`MethodChannel::SetMethodCallHandler(nullptr)`）或者删掉
// MethodChannel，都会进到已经拆掉的 messenger（`FlutterDesktopMessengerSetCallback`
// 访问冲突，和 bonsoir 在 Windows 上的退出崩溃是同一类）。所以回调只捕获这份状态，
// 不捕获插件对象，插件死掉以后留在这里的东西都还能安全地用（进程马上就结束了）。
struct PluginState {
  SmtcService* service = nullptr;
  flutter::MethodChannel<flutter::EncodableValue>* channel = nullptr;
  // 插件销毁后丢弃还在路上的事件
  bool alive = false;
  // 只写一次相同内容的日志，避免每秒一条把文件写满
  std::set<std::string> logged;
  // 已经写过的行数，防止异常情况下持续写文件
  int lines = 0;
  // 上一次记过的开关状态：-1 未记过，0 关，1 开
  int logged_enabled = -1;
};

PluginState* State() {
  static PluginState* state = new PluginState();
  return state;
}

// 不过滤地写一条（总数有上限）
void LogLine(const std::string& line) {
  PluginState* state = State();
  if (state->lines >= 80) {
    return;
  }
  ++state->lines;
  AppendSmtcLog(line);
}

void LogOnce(const std::string& line) {
  PluginState* state = State();
  // 最多留 40 条，避免异常情况下持续写文件
  if (state->logged.size() >= 40 || state->logged.count(line) != 0) {
    return;
  }
  state->logged.insert(line);
  LogLine(line);
}

// SMTC 的事件来自系统线程（不固定），直接发给 Dart：通道发送本身是线程安全的。
// 插件已销毁时丢弃。
void PostEvent(const std::string& event, flutter::EncodableValue value) {
  PluginState* state = State();
  if (!state->alive || state->channel == nullptr) {
    return;
  }
  state->channel->InvokeMethod(
      event, std::make_unique<flutter::EncodableValue>(std::move(value)));
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  PluginState* state = State();
  if (state->service == nullptr) {
    result->Error("no_service", "SMTC service is not ready");
    return;
  }
  SmtcService& service = *state->service;

  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (!args) {
    if (method == "clearMetadata") {
      result->Success(flutter::EncodableValue(service.ClearMetadata()));
      return;
    }
    result->Error("bad_args", "expected a map of arguments");
    return;
  }

  if (method == "setEnabled") {
    const bool enabled = GetBool(*args, "enabled", true);
    const bool ok = service.SetEnabled(enabled);
    // 值变了才记：能看出最后真正生效的是开还是关
    const int enabled_state = enabled ? 1 : 0;
    if (state->logged_enabled != enabled_state) {
      state->logged_enabled = enabled_state;
      LogLine(std::string("setEnabled ") + (enabled ? "true" : "false") +
              (ok ? " ok" : " fail"));
    }
    result->Success(flutter::EncodableValue(ok));
    return;
  }
  if (method == "setConfig") {
    const bool ok = service.SetConfig(
        GetBool(*args, "play", true), GetBool(*args, "pause", true),
        GetBool(*args, "next", true), GetBool(*args, "previous", true),
        GetBool(*args, "stop", true), GetBool(*args, "fastForward", true),
        GetBool(*args, "rewind", true));
    result->Success(flutter::EncodableValue(ok));
    return;
  }
  if (method == "updateMetadata") {
    const bool ok = service.UpdateMetadata(
        GetString(*args, "title"), GetString(*args, "artist"),
        GetString(*args, "album"), GetString(*args, "albumArtist"),
        GetString(*args, "thumbnail"));
    LogOnce(std::string("updateMetadata ") + (ok ? "ok" : "fail"));
    result->Success(flutter::EncodableValue(ok));
    return;
  }
  if (method == "updateTimeline") {
    const bool ok = service.UpdateTimeline(
        GetInt(*args, "positionMs", -1), GetInt(*args, "startMs", -1),
        GetInt(*args, "endMs", -1), GetInt(*args, "minSeekMs", -1),
        GetInt(*args, "maxSeekMs", -1));
    if (!ok) {
      LogOnce("updateTimeline fail");
    }
    result->Success(flutter::EncodableValue(ok));
    return;
  }
  if (method == "updatePlaybackStatus") {
    const bool ok = service.UpdatePlaybackStatus(GetString(*args, "status"));
    LogOnce(std::string("updatePlaybackStatus ") + (ok ? "ok" : "fail"));
    result->Success(flutter::EncodableValue(ok));
    return;
  }
  if (method == "setShuffle") {
    result->Success(flutter::EncodableValue(
        service.SetShuffle(GetBool(*args, "enabled", false))));
    return;
  }
  if (method == "setRepeatMode") {
    result->Success(flutter::EncodableValue(
        service.SetRepeatMode(GetString(*args, "mode"))));
    return;
  }

  result->NotImplemented();
}

// SMTC 是进程 / 窗口级的，注册多次也共用一份
SmtcService& SharedService() {
  static SmtcService service;
  return service;
}

}  // namespace

// 把 channel 上的方法转给 SmtcService，把 SMTC 的事件转回 Dart
class SmtcAudioServicePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit SmtcAudioServicePlugin(flutter::PluginRegistrarWindows* registrar);
  ~SmtcAudioServicePlugin() override;

  SmtcAudioServicePlugin(const SmtcAudioServicePlugin&) = delete;
  SmtcAudioServicePlugin& operator=(const SmtcAudioServicePlugin&) = delete;

 private:
  SmtcService& service_;
};

SmtcAudioServicePlugin::SmtcAudioServicePlugin(
    flutter::PluginRegistrarWindows* registrar)
    : service_(SharedService()) {
  PluginState* state = State();
  state->service = &service_;
  state->alive = true;

  // 方法回调与 channel 只建一次（见 PluginState 的注释）
  if (state->channel == nullptr) {
    state->channel = new flutter::MethodChannel<flutter::EncodableValue>(
        registrar->messenger(), kChannelName,
        &flutter::StandardMethodCodec::GetInstance());
    state->channel->SetMethodCallHandler(HandleMethodCall);
  }

  // 插件注册时主窗口已存在（还没显示），用它建 SMTC；
  // 取不到时后面的每次调用都会再试一遍
  HWND view_window = nullptr;
  if (flutter::FlutterView* view = registrar->GetView()) {
    view_window = view->GetNativeWindow();
  }
  service_.SetWindowProvider(
      [view_window]() { return ResolveHostWindow(view_window); });

  const bool created = service_.Initialize(view_window);
  const HWND host = service_.window();
  const std::string view_text = std::to_string(
      static_cast<uint64_t>(reinterpret_cast<uintptr_t>(view_window)));
  const std::string host_text =
      std::to_string(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(host)));
  AppendSmtcLog("init pid=" + std::to_string(::GetCurrentProcessId()) +
                " view=" + view_text + " host=" + host_text + " viewClass=" +
                WideToUtf8(WindowClassOf(view_window)) +
                " hostClass=" + WideToUtf8(WindowClassOf(host)) +
                " ok=" + (created ? "1" : "0") +
                " hr=" +
                std::to_string(static_cast<int32_t>(service_.last_result())));

  // 回调只捕获进程级状态，不捕获插件对象：插件在引擎析构时就被销毁了
  service_.SetButtonCallback([](const std::wstring& button) {
    PostEvent("buttonPressed", flutter::EncodableValue(WideToUtf8(button)));
  });
  service_.SetPositionCallback([](int64_t position_ms) {
    PostEvent("positionChangeRequested", flutter::EncodableValue(position_ms));
  });
  service_.SetShuffleCallback([](bool enabled) {
    PostEvent("shuffleChangeRequested", flutter::EncodableValue(enabled));
  });
  service_.SetRepeatCallback([](const std::wstring& mode) {
    PostEvent("repeatModeChangeRequested",
              flutter::EncodableValue(WideToUtf8(mode)));
  });
}

SmtcAudioServicePlugin::~SmtcAudioServicePlugin() {
  // 不要在这里摘方法回调、也不要删 channel：引擎正在拆，碰 messenger 会崩。
  // 只把 SMTC 自己占的东西收掉（COM 这时还可用），避免进程退出时在静态析构里再走一遍。
  State()->alive = false;
  service_.Shutdown();
}

void SmtcAudioServicePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<SmtcAudioServicePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

void SmtcAudioServicePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  SmtcAudioServicePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
