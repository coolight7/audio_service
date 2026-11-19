#include "smtc_service.h"

#include <roapi.h>
#include <winstring.h>
// Microsoft::WRL::Callback 在 wrl/event.h 里
#include <wrl/event.h>

#include <utility>

namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

// WinRT 的时间单位是 100 纳秒
constexpr int64_t kTimeSpanPerMillisecond = 10000;

int64_t MillisecondsToTimeSpan(int64_t milliseconds) {
  return milliseconds * kTimeSpanPerMillisecond;
}

int64_t TimeSpanToMilliseconds(int64_t time_span) {
  return time_span / kTimeSpanPerMillisecond;
}

std::wstring ButtonName(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton_Play:
      return L"play";
    case SystemMediaTransportControlsButton_Pause:
      return L"pause";
    case SystemMediaTransportControlsButton_Next:
      return L"next";
    case SystemMediaTransportControlsButton_Previous:
      return L"previous";
    case SystemMediaTransportControlsButton_Stop:
      return L"stop";
    case SystemMediaTransportControlsButton_FastForward:
      return L"fastForward";
    case SystemMediaTransportControlsButton_Rewind:
      return L"rewind";
    case SystemMediaTransportControlsButton_Record:
      return L"record";
    case SystemMediaTransportControlsButton_ChannelUp:
      return L"channelUp";
    case SystemMediaTransportControlsButton_ChannelDown:
      return L"channelDown";
    default:
      return L"unknown";
  }
}

MediaPlaybackStatus PlaybackStatusFromName(const std::wstring& status) {
  if (status == L"playing") {
    return MediaPlaybackStatus_Playing;
  }
  if (status == L"paused") {
    return MediaPlaybackStatus_Paused;
  }
  if (status == L"stopped") {
    return MediaPlaybackStatus_Stopped;
  }
  if (status == L"changing") {
    return MediaPlaybackStatus_Changing;
  }
  // 没有元数据时用 Closed，媒体面板会收起
  return MediaPlaybackStatus_Closed;
}

MediaPlaybackAutoRepeatMode RepeatModeFromName(const std::wstring& mode) {
  if (mode == L"track") {
    return MediaPlaybackAutoRepeatMode_Track;
  }
  if (mode == L"list") {
    return MediaPlaybackAutoRepeatMode_List;
  }
  return MediaPlaybackAutoRepeatMode_None;
}

}  // namespace

SmtcService::~SmtcService() { UnregisterEvents(); }

bool SmtcService::Initialize(HWND window) {
  if (window != nullptr) {
    fallback_window_ = window;
  }
  return EnsureInitialized();
}

bool SmtcService::EnsureInitialized() {
  if (smtc_) {
    return true;
  }
  // 插件注册时拿到的是 Flutter 的 view 窗口（主窗口的子窗口），
  // 拿它调 GetForWindow 会返回 E_INVALIDARG，这里用调用方给的方法换主窗口
  HWND window = window_provider_ ? window_provider_() : fallback_window_;
  if (window == nullptr || !::IsWindow(window)) {
    last_result_ = E_INVALIDARG;
    return false;
  }
  window_ = window;

  ComPtr<ISystemMediaTransportControlsInterop> interop;
  HRESULT hr = ::RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControls)
          .Get(),
      IID_PPV_ARGS(&interop));
  if (FAILED(hr) || !interop) {
    last_result_ = hr;
    return false;
  }

  // 直接绑到主窗口：不需要 UWP MediaPlayer，也就不会拉起 Media Foundation
  hr = interop->GetForWindow(window_, IID_PPV_ARGS(&smtc_));
  if (FAILED(hr) || !smtc_) {
    smtc_.Reset();
    last_result_ = hr;
    return false;
  }

  // 时间轴 / 随机 / 循环 / 进度拖动只在 2 代接口上；
  // 取不到时保留基础功能（开关、元数据、按钮）
  if (FAILED(smtc_.As(&smtc2_))) {
    smtc2_.Reset();
  }

  RegisterEvents();
  last_result_ = S_OK;
  // 初始化成功前设过的开关状态补写一次
  if (has_enabled_) {
    smtc_->put_IsEnabled(enabled_ ? TRUE : FALSE);
  }
  return true;
}

void SmtcService::SetWindowProvider(WindowProvider provider) {
  window_provider_ = std::move(provider);
}

void SmtcService::SetButtonCallback(ButtonCallback callback) {
  button_callback_ = std::move(callback);
}

void SmtcService::SetPositionCallback(PositionCallback callback) {
  position_callback_ = std::move(callback);
}

void SmtcService::SetShuffleCallback(ShuffleCallback callback) {
  shuffle_callback_ = std::move(callback);
}

void SmtcService::SetRepeatCallback(RepeatCallback callback) {
  repeat_callback_ = std::move(callback);
}

void SmtcService::Shutdown() {
  UnregisterEvents();
  button_callback_ = nullptr;
  position_callback_ = nullptr;
  shuffle_callback_ = nullptr;
  repeat_callback_ = nullptr;
  smtc2_.Reset();
  smtc_.Reset();
  window_ = nullptr;
}

bool SmtcService::SetEnabled(bool enabled) {
  // 先记下意图：初始化还不成功时，等它成功后会补写
  has_enabled_ = true;
  enabled_ = enabled;
  if (!EnsureInitialized()) {
    return false;
  }
  return SUCCEEDED(smtc_->put_IsEnabled(enabled_ ? TRUE : FALSE));
}

bool SmtcService::SetConfig(bool play, bool pause, bool next, bool previous,
                            bool stop, bool fast_forward, bool rewind) {
  if (!EnsureInitialized()) {
    return false;
  }
  bool ok = SUCCEEDED(smtc_->put_IsPlayEnabled(play ? TRUE : FALSE));
  ok = SUCCEEDED(smtc_->put_IsPauseEnabled(pause ? TRUE : FALSE)) && ok;
  ok = SUCCEEDED(smtc_->put_IsNextEnabled(next ? TRUE : FALSE)) && ok;
  ok = SUCCEEDED(smtc_->put_IsPreviousEnabled(previous ? TRUE : FALSE)) && ok;
  ok = SUCCEEDED(smtc_->put_IsStopEnabled(stop ? TRUE : FALSE)) && ok;
  ok = SUCCEEDED(smtc_->put_IsFastForwardEnabled(fast_forward ? TRUE : FALSE)) &&
       ok;
  ok = SUCCEEDED(smtc_->put_IsRewindEnabled(rewind ? TRUE : FALSE)) && ok;
  return ok;
}

bool SmtcService::UpdateMetadata(const std::wstring& title,
                                 const std::wstring& artist,
                                 const std::wstring& album,
                                 const std::wstring& album_artist,
                                 const std::wstring& thumbnail_uri) {
  if (!EnsureInitialized()) {
    return false;
  }

  ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
  if (FAILED(smtc_->get_DisplayUpdater(&updater)) || !updater) {
    return false;
  }

  updater->put_Type(MediaPlaybackType_Music);

  ComPtr<IMusicDisplayProperties> music;
  if (SUCCEEDED(updater->get_MusicProperties(&music)) && music) {
    // 四个字段都无条件写：空值也要写成空，否则上一首（或启动时的占位项）的值会留下来
    music->put_Title(HStringReference(title.c_str()).Get());
    music->put_Artist(HStringReference(artist.c_str()).Get());
    music->put_AlbumArtist(HStringReference(album_artist.c_str()).Get());
    // 专辑名在 2 代接口上（1 代只有标题 / 歌手 / 专辑歌手）
    ComPtr<IMusicDisplayProperties2> music2;
    if (SUCCEEDED(music.As(&music2)) && music2) {
      music2->put_AlbumTitle(HStringReference(album.c_str()).Get());
    }
  }

  if (thumbnail_uri.empty()) {
    // 没有封面时清掉上一张，否则面板会一直显示上一首的图
    updater->put_Thumbnail(nullptr);
  } else {
    ComPtr<IUriRuntimeClassFactory> uri_factory;
    if (SUCCEEDED(::RoGetActivationFactory(
            HStringReference(RuntimeClass_Windows_Foundation_Uri).Get(),
            IID_PPV_ARGS(&uri_factory))) &&
        uri_factory) {
      ComPtr<IUriRuntimeClass> uri;
      if (SUCCEEDED(uri_factory->CreateUri(
              HStringReference(thumbnail_uri.c_str()).Get(), &uri)) &&
          uri) {
        ComPtr<IRandomAccessStreamReferenceStatics> stream_statics;
        if (SUCCEEDED(::RoGetActivationFactory(
                HStringReference(
                    RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference)
                    .Get(),
                IID_PPV_ARGS(&stream_statics))) &&
            stream_statics) {
          ComPtr<IRandomAccessStreamReference> thumbnail;
          if (SUCCEEDED(
                  stream_statics->CreateFromUri(uri.Get(), &thumbnail)) &&
              thumbnail) {
            updater->put_Thumbnail(thumbnail.Get());
          }
        }
      }
    }
  }

  return SUCCEEDED(updater->Update());
}

bool SmtcService::ClearMetadata() {
  if (!EnsureInitialized()) {
    return false;
  }
  ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
  if (FAILED(smtc_->get_DisplayUpdater(&updater)) || !updater) {
    return false;
  }
  updater->ClearAll();
  return SUCCEEDED(updater->Update());
}

bool SmtcService::UpdateTimeline(int64_t position_ms, int64_t start_ms,
                                 int64_t end_ms, int64_t min_seek_ms,
                                 int64_t max_seek_ms) {
  if (!EnsureInitialized() || !smtc2_) {
    return false;
  }

  ComPtr<IInspectable> inspectable;
  HRESULT hr = ::RoActivateInstance(
      HStringReference(
          RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties)
          .Get(),
      &inspectable);
  if (FAILED(hr) || !inspectable) {
    return false;
  }

  ComPtr<ISystemMediaTransportControlsTimelineProperties> properties;
  hr = inspectable.As(&properties);
  if (FAILED(hr) || !properties) {
    return false;
  }

  if (start_ms >= 0) {
    properties->put_StartTime({MillisecondsToTimeSpan(start_ms)});
  }
  if (end_ms >= 0) {
    properties->put_EndTime({MillisecondsToTimeSpan(end_ms)});
  }
  if (position_ms >= 0) {
    properties->put_Position({MillisecondsToTimeSpan(position_ms)});
  }
  if (min_seek_ms >= 0) {
    properties->put_MinSeekTime({MillisecondsToTimeSpan(min_seek_ms)});
  }
  if (max_seek_ms >= 0) {
    properties->put_MaxSeekTime({MillisecondsToTimeSpan(max_seek_ms)});
  }

  return SUCCEEDED(smtc2_->UpdateTimelineProperties(properties.Get()));
}

bool SmtcService::UpdatePlaybackStatus(const std::wstring& status) {
  if (!EnsureInitialized()) {
    return false;
  }
  return SUCCEEDED(smtc_->put_PlaybackStatus(PlaybackStatusFromName(status)));
}

bool SmtcService::SetShuffle(bool enabled) {
  if (!EnsureInitialized() || !smtc2_) {
    return false;
  }
  return SUCCEEDED(smtc2_->put_ShuffleEnabled(enabled ? TRUE : FALSE));
}

bool SmtcService::SetRepeatMode(const std::wstring& mode) {
  if (!EnsureInitialized() || !smtc2_) {
    return false;
  }
  return SUCCEEDED(smtc2_->put_AutoRepeatMode(RepeatModeFromName(mode)));
}

void SmtcService::RegisterEvents() {
  if (!smtc_ || events_registered_) {
    return;
  }

  auto button_handler = Microsoft::WRL::Callback<
      ITypedEventHandler<SystemMediaTransportControls*,
                         SystemMediaTransportControlsButtonPressedEventArgs*>>(
      [this](ISystemMediaTransportControls*,
             ISystemMediaTransportControlsButtonPressedEventArgs* args)
          -> HRESULT {
        if (args != nullptr && button_callback_) {
          SystemMediaTransportControlsButton button =
              SystemMediaTransportControlsButton_Play;
          if (SUCCEEDED(args->get_Button(&button))) {
            button_callback_(ButtonName(button));
          }
        }
        return S_OK;
      });
  if (button_handler) {
    smtc_->add_ButtonPressed(button_handler.Get(), &button_token_);
  }

  auto position_handler = Microsoft::WRL::Callback<
      ITypedEventHandler<SystemMediaTransportControls*,
                         PlaybackPositionChangeRequestedEventArgs*>>(
      [this](ISystemMediaTransportControls*,
             IPlaybackPositionChangeRequestedEventArgs* args) -> HRESULT {
        if (args != nullptr && position_callback_) {
          TimeSpan position{};
          if (SUCCEEDED(args->get_RequestedPlaybackPosition(&position))) {
            position_callback_(TimeSpanToMilliseconds(position.Duration));
          }
        }
        return S_OK;
      });
  // 进度拖动 / 随机 / 循环都只在 2 代接口上
  if (position_handler && smtc2_) {
    smtc2_->add_PlaybackPositionChangeRequested(position_handler.Get(),
                                                &position_token_);
  }

  auto shuffle_handler = Microsoft::WRL::Callback<
      ITypedEventHandler<SystemMediaTransportControls*,
                         ShuffleEnabledChangeRequestedEventArgs*>>(
      [this](ISystemMediaTransportControls*,
             IShuffleEnabledChangeRequestedEventArgs* args) -> HRESULT {
        if (args != nullptr && shuffle_callback_) {
          BOOLEAN enabled = FALSE;
          if (SUCCEEDED(args->get_RequestedShuffleEnabled(&enabled))) {
            shuffle_callback_(enabled != FALSE);
          }
        }
        return S_OK;
      });
  if (shuffle_handler && smtc2_) {
    smtc2_->add_ShuffleEnabledChangeRequested(shuffle_handler.Get(),
                                              &shuffle_token_);
  }

  auto repeat_handler = Microsoft::WRL::Callback<
      ITypedEventHandler<SystemMediaTransportControls*,
                         AutoRepeatModeChangeRequestedEventArgs*>>(
      [this](ISystemMediaTransportControls*,
             IAutoRepeatModeChangeRequestedEventArgs* args) -> HRESULT {
        if (args != nullptr && repeat_callback_) {
          MediaPlaybackAutoRepeatMode mode =
              MediaPlaybackAutoRepeatMode_None;
          if (SUCCEEDED(args->get_RequestedAutoRepeatMode(&mode))) {
            switch (mode) {
              case MediaPlaybackAutoRepeatMode_Track:
                repeat_callback_(L"track");
                break;
              case MediaPlaybackAutoRepeatMode_List:
                repeat_callback_(L"list");
                break;
              default:
                repeat_callback_(L"none");
                break;
            }
          }
        }
        return S_OK;
      });
  if (repeat_handler && smtc2_) {
    smtc2_->add_AutoRepeatModeChangeRequested(repeat_handler.Get(),
                                              &repeat_token_);
  }

  events_registered_ = true;
}

void SmtcService::UnregisterEvents() {
  if (!smtc_ || !events_registered_) {
    return;
  }
  smtc_->remove_ButtonPressed(button_token_);
  if (smtc2_) {
    smtc2_->remove_PlaybackPositionChangeRequested(position_token_);
    smtc2_->remove_ShuffleEnabledChangeRequested(shuffle_token_);
    smtc2_->remove_AutoRepeatModeChangeRequested(repeat_token_);
  }
  events_registered_ = false;
}
