import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'audio_service_platform_interface.dart';

class SMTCAudioService extends AudioServicePlatform {
  final smtc = SMTCWindows(
    config: const SMTCConfig(
      playEnabled: true,
      pauseEnabled: true,
      nextEnabled: true,
      prevEnabled: true,
      stopEnabled: true,
      fastForwardEnabled: true,
      rewindEnabled: true,
    ),
    metadata: const MusicMetadata(
      title: 'Title',
      album: 'Album',
      albumArtist: 'Album Artist',
      artist: 'Artist',
    ),
    timeline: const PlaybackTimeline(
      startTimeMs: 0,
      endTimeMs: 1000,
      positionMs: 0,
      minSeekTimeMs: 0,
      maxSeekTimeMs: 1000,
    ),
  );

  MediaItemMessage? cacheMediaItem;
  StreamSubscription<PressedButton>? _buttonPressSubscription;

  AudioHandlerCallbacks? _callbacks;

  @override
  Future<void> configure(ConfigureRequest request) async {
    await smtc.enableSmtc();
    _buttonPressSubscription ??= smtc.buttonPressStream.listen((event) {
      switch (event) {
        case PressedButton.next:
          _callbacks?.skipToNext(const SkipToNextRequest());
          break;
        case PressedButton.previous:
          _callbacks?.skipToPrevious(const SkipToPreviousRequest());
          break;
        case PressedButton.play:
          _callbacks?.play(const PlayRequest());
          break;
        case PressedButton.pause:
          _callbacks?.pause(const PauseRequest());
          break;
        case PressedButton.stop:
          _callbacks?.stop(const StopRequest());
          break;
        case PressedButton.fastForward:
          _callbacks?.fastForward(const FastForwardRequest());
          break;
        case PressedButton.rewind:
          _callbacks?.rewind(const RewindRequest());
          break;
        case PressedButton.record:
        case PressedButton.channelUp:
        case PressedButton.channelDown:
          if (kDebugMode) {
            print(event);
          }
      }
    });
    smtc.setIsStopEnabled(true);
    smtc.setIsFastForwardEnabled(true);
    smtc.setIsRewindEnabled(true);
    smtc.setShuffleEnabled(true);
    await smtc.disableSmtc();
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    final state = request.state;
    bool previousEnabled = false;
    bool nextEnabled = false;
    for (var control in state.controls) {
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
    await smtc.setIsNextEnabled(nextEnabled);
    await smtc.setIsPrevEnabled(previousEnabled);
    await smtc.setPlaybackStatus(
      state.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
    );
    smtc.updateTimeline(PlaybackTimeline(
      startTimeMs: 0,
      endTimeMs: cacheMediaItem?.duration?.inMilliseconds ?? 7,
      positionMs: state.updatePosition.inMilliseconds,
    ));
  }

  @override
  Future<void> setQueue(SetQueueRequest request) {
    return SynchronousFuture(null);
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final item = request.mediaItem;
    String? url = item.artUri?.toString();
    // TODO: 本地图片异常
    cacheMediaItem = item;
    await smtc.updateMetadata(MusicMetadata(
      title: item.title,
      artist: item.artist,
      album: item.album,
      albumArtist: item.artist,
      thumbnail: url,
    ));
    if (false == smtc.enabled) {
      await smtc.enableSmtc();
    }
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    await smtc.disableSmtc();
  }

  @override
  Future<void> androidForceEnableMediaButtons(
      AndroidForceEnableMediaButtonsRequest request) {
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
}
