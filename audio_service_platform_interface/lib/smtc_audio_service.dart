import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_service_platform_interface.dart';

/// 系统媒体控件（SMTC）的按钮
///
/// 名字与原生侧（`windows/smtc_service.cpp` 的 `ButtonName`）一致。
enum SmtcButton {
  play,
  pause,
  next,
  previous,
  stop,
  fastForward,
  rewind,
  record,
  channelUp,
  channelDown;

  static SmtcButton? fromName(String? name) {
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}

/// Windows 的 audio_service 平台实现：把播放状态交给系统媒体控件（SMTC）
///
/// 原生侧在同一个包的 `windows/` 目录（C++ plugin），通过 [channelName] 与这里通信。
/// 调用失败（例如 plugin 没注册）不会影响播放，只是媒体面板不更新。
class SMTCAudioService extends AudioServicePlatform {
  /// 与原生侧 `smtc_audio_service_plugin.cpp` 的 `kChannelName` 相同
  static const String channelName = 'audio_service/smtc';

  static const MethodChannel _channel = MethodChannel(channelName);

  final StreamController<SmtcButton> _buttonController =
      StreamController<SmtcButton>.broadcast();

  MediaItemMessage? cacheMediaItem;

  StreamSubscription<SmtcButton>? _buttonPressSubscription;

  AudioHandlerCallbacks? _callbacks;

  bool _enabled = false;

  SMTCAudioService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Stream<SmtcButton> get buttonPressStream => _buttonController.stream;

  @override
  Future<void> configure(ConfigureRequest request) async {
    await _enable();
    _buttonPressSubscription ??= buttonPressStream.listen((event) {
      switch (event) {
        case SmtcButton.next:
          _callbacks?.skipToNext(const SkipToNextRequest());
          break;
        case SmtcButton.previous:
          _callbacks?.skipToPrevious(const SkipToPreviousRequest());
          break;
        case SmtcButton.play:
          _callbacks?.play(const PlayRequest());
          break;
        case SmtcButton.pause:
          _callbacks?.pause(const PauseRequest());
          break;
        case SmtcButton.stop:
          _callbacks?.stop(const StopRequest());
          break;
        case SmtcButton.fastForward:
          _callbacks?.fastForward(const FastForwardRequest());
          break;
        case SmtcButton.rewind:
          _callbacks?.rewind(const RewindRequest());
          break;
        case SmtcButton.record:
        case SmtcButton.channelUp:
        case SmtcButton.channelDown:
          if (kDebugMode) {
            debugPrint('SMTC 按钮未处理：$event');
          }
          break;
      }
    });
    await _invoke('setConfig', <String, dynamic>{
      'play': true,
      'pause': true,
      'next': true,
      'previous': true,
      'stop': true,
      'fastForward': true,
      'rewind': true,
    });
    await _invoke('setShuffle', <String, dynamic>{'enabled': true});
    // 与原来的行为一致：配置完先关掉，等有歌时再打开
    await _disable();
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    final state = request.state;
    bool previousEnabled = false;
    bool nextEnabled = false;
    for (final control in state.controls) {
      switch (control.action) {
        case MediaActionMessage.skipToNext:
          nextEnabled = true;
          break;
        case MediaActionMessage.skipToPrevious:
          previousEnabled = true;
          break;
        default:
          break;
      }
    }
    await _invoke('setConfig', <String, dynamic>{
      'play': true,
      'pause': true,
      'next': nextEnabled,
      'previous': previousEnabled,
      'stop': true,
      'fastForward': true,
      'rewind': true,
    });
    await _invoke('updatePlaybackStatus', <String, dynamic>{
      'status': state.playing ? 'playing' : 'paused',
    });
    // 媒体面板的进度条能不能拖由「可拖动区间」决定：只写 position / end 时
    // MinSeekTime / MaxSeekTime 整段还是 0，面板就不画进度条。
    // 时长未知时不写区间（宁可不出现进度条，也不要一条 7ms 的假进度）
    final int? durationMs = cacheMediaItem?.duration?.inMilliseconds;
    unawaited(
      _invoke('updateTimeline', <String, dynamic>{
        'positionMs': state.updatePosition.inMilliseconds,
        'startMs': 0,
        'endMs': durationMs ?? 7,
        if (durationMs != null && durationMs > 0) ...<String, dynamic>{
          'minSeekMs': 0,
          'maxSeekMs': durationMs,
        },
      }),
    );
  }

  @override
  Future<void> setQueue(SetQueueRequest request) {
    return SynchronousFuture(null);
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final item = request.mediaItem;
    cacheMediaItem = item;
    await _invoke('updateMetadata', <String, dynamic>{
      'title': item.title,
      'artist': item.artist,
      'album': item.album,
      'albumArtist': item.artist,
      'thumbnail': item.artUri?.toString(),
    });
    if (!_enabled) {
      await _enable();
    }
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    await _disable();
  }

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) {
    return SynchronousFuture(null);
  }

  @override
  Future<void> notifyChildrenChanged(NotifyChildrenChangedRequest request) {
    return SynchronousFuture(null);
  }

  @override
  Future<void> setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest request) {
    return SynchronousFuture(null);
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    _callbacks = callbacks;
  }

  Future<void> _enable() async {
    final result =
        await _invoke('setEnabled', <String, dynamic>{'enabled': true});
    // 原生侧在窗口还没建好时会失败，这时不记成已开启，
    // 下次设置媒体项时会再试一次
    _enabled = result == true;
  }

  Future<void> _disable() async {
    await _invoke('setEnabled', <String, dynamic>{'enabled': false});
    // 关闭失败时也当成没开启，下次有歌时再打开
    _enabled = false;
  }

  /// 原生侧的事件回调
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'buttonPressed':
        final button = SmtcButton.fromName(
          call.arguments is String ? call.arguments as String : null,
        );
        if (button != null) {
          _buttonController.add(button);
        }
        break;
      case 'positionChangeRequested':
      case 'shuffleChangeRequested':
      case 'repeatModeChangeRequested':
        // 项目没有用到这三个事件（与原来的 Rust 实现一样只监听按钮）
        break;
    }
    return null;
  }

  Future<dynamic> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<dynamic>(method, arguments);
    } on MissingPluginException {
      // 非 Windows 平台或 plugin 未注册：不影响播放
      return null;
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('SMTC $method 调用失败：$error\n$stack');
      }
      return null;
    }
  }
}
