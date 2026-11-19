#pragma once

#include <windows.h>

#include <eventtoken.h>
#include <systemmediatransportcontrolsinterop.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <windows.storage.streams.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <cstdint>
#include <functional>
#include <string>

// WinRT 的 ABI 接口声明在 ABI:: 命名空间下（windows.media.h 等头里）
// 这里用短名，方便下面写 ComPtr<ISystemMediaTransportControls> 这类类型
using namespace ABI::Windows::Foundation;
using namespace ABI::Windows::Media;
using namespace ABI::Windows::Storage::Streams;

// Windows 系统媒体控件（SMTC）的封装
// * 绑定到主窗口，一个进程一个实例
// * 只做 Win32 / COM 这一侧的事：开关、按钮配置、元数据、时间轴、播放状态
// * 事件回调在系统线程上触发，调用方自己负责转回需要的线程
class SmtcService {
 public:
  using ButtonCallback = std::function<void(const std::wstring& button)>;
  using PositionCallback = std::function<void(int64_t position_ms)>;
  using ShuffleCallback = std::function<void(bool enabled)>;
  using RepeatCallback = std::function<void(const std::wstring& mode)>;

  SmtcService() = default;
  ~SmtcService();

  SmtcService(const SmtcService&) = delete;
  SmtcService& operator=(const SmtcService&) = delete;

  // 找主窗口的方式由调用方提供（插件注册时拿到的 view 窗口不是主窗口，
  // 且那时主窗口还没显示，所以每次初始化前重新找一次）
  using WindowProvider = std::function<HWND()>;
  void SetWindowProvider(WindowProvider provider);

  // 创建 SMTC 并绑定窗口；窗口为空或系统不支持时返回 false
  // * 允许在窗口还没显示时调用：拿不到窗口就等下一次调用再试
  bool Initialize(HWND window);

  // 最近一次初始化的 HRESULT（排查用）
  HRESULT last_result() const { return last_result_; }

  // 已经绑定的窗口（初始化失败时为 nullptr，排查用）
  HWND window() const { return window_; }

  void SetButtonCallback(ButtonCallback callback);
  void SetPositionCallback(PositionCallback callback);
  void SetShuffleCallback(ShuffleCallback callback);
  void SetRepeatCallback(RepeatCallback callback);

  // 揉掉窗口事件并释放 SMTC（插件随引擎析构时调用：那时 COM 还能用，
  // 不能留到 DLL 卸载时的静态析构）
  void Shutdown();

  bool SetEnabled(bool enabled);
  bool SetConfig(bool play, bool pause, bool next, bool previous, bool stop,
                 bool fast_forward, bool rewind);
  bool UpdateMetadata(const std::wstring& title, const std::wstring& artist,
                      const std::wstring& album,
                      const std::wstring& album_artist,
                      const std::wstring& thumbnail_uri);
  bool ClearMetadata();
  // 时间单位都是毫秒，负数表示这一项不更新
  bool UpdateTimeline(int64_t position_ms, int64_t start_ms, int64_t end_ms,
                      int64_t min_seek_ms, int64_t max_seek_ms);
  // status: playing / paused / stopped / changing / closed
  bool UpdatePlaybackStatus(const std::wstring& status);
  bool SetShuffle(bool enabled);
  // mode: none / track / list
  bool SetRepeatMode(const std::wstring& mode);

 private:
  // 懒初始化：插件注册时窗口往往还没显示，GetForWindow 会返回 E_INVALIDARG，
  // 等真正要用（播放状态 / 元数据）时窗口已经在屏幕上，那时再建。
  bool EnsureInitialized();
  void RegisterEvents();
  void UnregisterEvents();

  // 绑定成功的窗口
  HWND window_ = nullptr;
  // 调用方给的候选窗口，只在没有 WindowProvider 时用
  HWND fallback_window_ = nullptr;
  WindowProvider window_provider_;
  // 早于初始化成功时设过的开关状态，初始化成功后补写一次
  // （Dart 侧只在媒体项变化时才再调 setEnabled，不补的话媒体面板可能一直不出现）
  bool has_enabled_ = false;
  bool enabled_ = false;
  Microsoft::WRL::ComPtr<ISystemMediaTransportControls> smtc_;
  // 时间轴、随机、循环、进度拖动只在 2 代接口上；取不到时这些功能静默不生效
  Microsoft::WRL::ComPtr<ISystemMediaTransportControls2> smtc2_;

  ButtonCallback button_callback_;
  PositionCallback position_callback_;
  ShuffleCallback shuffle_callback_;
  RepeatCallback repeat_callback_;

  EventRegistrationToken button_token_{};
  EventRegistrationToken position_token_{};
  EventRegistrationToken shuffle_token_{};
  EventRegistrationToken repeat_token_{};
  bool events_registered_ = false;
  HRESULT last_result_ = S_OK;
};
