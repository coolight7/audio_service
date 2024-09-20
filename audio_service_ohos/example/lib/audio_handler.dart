/*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart'; // 用于获取应用目录
import 'package:rxdart/rxdart.dart';


class AudioPlayerHandlerImpl extends BaseAudioHandler
    with SeekHandler
    implements AudioPlayerHandler {
  final AudioPlayer _audioPlayer = AudioPlayer()
    ..setReleaseMode(ReleaseMode.stop);
  Duration currentPosition = Duration.zero;

  Stream<Duration> get durationStream => createPositionStream(
      steps: 800,
      minPeriod: const Duration(milliseconds: 16),
      maxPeriod: const Duration(milliseconds: 200));

  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    assert(minPeriod <= maxPeriod);
    assert(minPeriod > Duration.zero);
    Duration? last;
    late StreamController<Duration> controller;
    late StreamSubscription<MediaItem?> mediaItemSubscription;
    late StreamSubscription<PlaybackState> playbackStateSubscription;
    Timer? currentTimer;
    Duration duration() => mediaItem.value?.duration ?? Duration.zero;
    Duration step() {
      var s = duration() ~/ steps;
      if (s < minPeriod) s = minPeriod;
      if (s > maxPeriod) s = maxPeriod;
      return s;
    }

    void yieldPosition(Timer? timer) {
      _audioPlayer.getCurrentPosition().then((value) {
        currentPosition = value ?? Duration.zero;
        if (last != currentPosition && currentPosition.inMilliseconds != -1) {
          controller.add(last = currentPosition);
        }
      });
    }

    controller = StreamController.broadcast(
      sync: true,
      onListen: () {
        mediaItemSubscription = mediaItem.listen((MediaItem? mediaItem) {
          // Potentially a new duration
          currentTimer?.cancel();
          currentTimer = Timer.periodic(step(), yieldPosition);
        });
        playbackStateSubscription = playbackState.listen((PlaybackState state) {
          // Potentially a time discontinuity
          yieldPosition(currentTimer);
        });
      },
      onCancel: () {
        mediaItemSubscription.cancel();
        playbackStateSubscription.cancel();
      },
    );
    return controller.stream;
  }

  // 播放列表 , 换成原项目MediaItem资源
  final List<MediaItem> _playlist = [
    MediaItem(
      id: 'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3',
      album: "Science Friday",
      title: "A Salute To Head-Scratching Science",
      artist: "Science Friday and WNYC Studios",
      duration: const Duration(milliseconds: 5739820),
      artUri: Uri.parse(
          'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
    ),
    MediaItem(
      id: 'https://s3.amazonaws.com/scifri-segments/scifri201711241.mp3',
      album: "Science Friday",
      title: "From Cat Rheology To Operatic Incompetence",
      artist: "Science Friday and WNYC Studios",
      duration: const Duration(milliseconds: 2856950),
      artUri: Uri.parse(
          'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
    ),
    MediaItem(
      id: 'https://s3.amazonaws.com/scifri-segments/scifri202011274.mp3',
      album: "Science Friday",
      title: "Laugh Along At Home With The Ig Nobel Awards",
      artist: "Science Friday and WNYC Studios",
      duration: const Duration(milliseconds: 1791883),
      artUri: Uri.parse(
          'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
    )
  ];

  int _currentIndex = 0;
  bool _isLoading = false;
  PlayerState state = PlayerState.disposed;
  Duration _duration = Duration.zero;
  final _mediaLibrary = MediaLibrary();
  AudioServiceRepeatMode _loopMode = AudioServiceRepeatMode.none;

  final BehaviorSubject<List<MediaItem>> _recentSubject =
      BehaviorSubject.seeded(<MediaItem>[]);

  Duration d = Duration.zero;
  StreamSubscription<Duration>? subscription;

  final _controller = StreamController<Duration>.broadcast();

  @override
  final BehaviorSubject<double> volume = BehaviorSubject.seeded(1.0);
  @override
  final BehaviorSubject<double> speed = BehaviorSubject.seeded(1.0);

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _playlist.add(mediaItem);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _playlist.addAll(mediaItems);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    _playlist.insert(index, mediaItem);
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    _playlist.addAll(queue);
  }

  Stream<Duration> get stream => _controller.stream;

  AudioPlayerHandlerImpl() {
    _audioPlayer.onPlayerStateChanged.listen((state) async {
      print('onPlayerStateChanged $state');
      this.state = state;
      if (state == PlayerState.completed) {
        switch (_loopMode) {
          case AudioServiceRepeatMode.none:
            if (_currentIndex < _playlist.length - 1) {
              _currentIndex = _currentIndex + 1;
              play();
            } else {
              playbackState.add(playbackState.value.copyWith(
                processingState: AudioProcessingState.completed,
                playing: false,
              ));
            }
            break;
          case AudioServiceRepeatMode.one:
            play();
            break;
          case AudioServiceRepeatMode.all:
            _currentIndex =
                _currentIndex < _playlist.length - 1 ? _currentIndex + 1 : 0;
            play();
            break;
          default:
        }
      } else if (state == PlayerState.playing) {
        _duration = await _audioPlayer.getDuration() as Duration;
        print(_duration.inMilliseconds.toString());
        playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.ready,
            playing: true,
            controls: [
              MediaControl.skipToPrevious,
              MediaControl.pause,
              MediaControl.stop,
              MediaControl.skipToNext,
            ],
            bufferedPosition: _duration,
            updatePosition: currentPosition));
        _isLoading = false;
      } else if (state == PlayerState.paused) {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          bufferedPosition: _duration,
          updatePosition: currentPosition,
          playing: false,
          controls: [
            MediaControl.skipToPrevious,
            MediaControl.play,
            MediaControl.stop,
            MediaControl.skipToNext,
          ],
        ));
      }
    });
    mediaItem.add(_playlist[0]);
    queue.add(_playlist);
  }

  final _shuffleIndicesSubject = BehaviorSubject<List<int>?>();

  Stream<List<int>?> get shuffleIndicesStream => _shuffleIndicesSubject.stream;

  @override
  Future<void> play() async {
    if (_audioPlayer.state == PlayerState.paused) {
      await _audioPlayer.resume();
    } else {
      await _audioPlayer.stop();
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
      ));
      mediaItem.add(_playlist[_currentIndex]);

      await _audioPlayer.play(UrlSource(_playlist[_currentIndex].id));
    }
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.ready,
      playing: true,
    ));
  }

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.ready,
      playing: false,
    ));
  }

  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero));
  }

  @override
  Future<void> seek(Duration position) async {
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
    await _audioPlayer.seek(position);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.ready,
      playing: true,
      controls: [
        MediaControl.pause,
        MediaControl.stop,
      ],
    ));
    this.mediaItem.add(mediaItem);
    await play();
  }

  @override
  Future<void> moveQueueItem(int currentIndex, int newIndex) {
    // 检查索引范围
    if (currentIndex < 0 ||
        currentIndex >= _playlist.length ||
        newIndex < 0 ||
        newIndex >= _playlist.length) {
      print('Invalid index');
    }
    MediaItem element = _playlist.removeAt(currentIndex);
    _playlist.insert(newIndex, element);

    return Future.value();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    // 被移除的是当前播放
    print('要移除的index :' +
        index.toString() +
        '当前播放的index : ' +
        _currentIndex.toString());
    _playlist.removeAt(index);
    //刷新列队
    queue.add(_playlist);
    if (index == _currentIndex) {
      if (_playlist.isNotEmpty) {
        _currentIndex = _currentIndex < _playlist.length
            ? _currentIndex
            : _currentIndex - 1;
        PlayerState currentState = state;
        await _audioPlayer.stop();
        if (currentState == PlayerState.playing) {
          play();
        }
      }
    } else if (index < _currentIndex) {
      //前进一位
      _currentIndex = _currentIndex - 1;
    }
    return Future.value();
  }

  Stream<QueueState> get queueState =>
      Rx.combineLatest2<List<MediaItem>, PlaybackState, QueueState>(
          queue,
          playbackState,
          (queue, playbackState) => QueueState(
                queue,
                _currentIndex,
                playbackState.repeatMode,
              ));

  @override
  Future<void> setSpeed(double speed) async {
    this.speed.add(speed);
    await _audioPlayer.setPlaybackRate(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume.add(volume);
    await _audioPlayer.setVolume(volume);
  }

  @override
  Future<void> skipToNext() async {
    if (_currentIndex + 1 < _playlist.length) {
      _currentIndex++;
    } else {
      _currentIndex = 0;
    }
    await _audioPlayer.stop();
    await play();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_currentIndex - 1 >= 0) {
      _currentIndex--;
    } else {
      _currentIndex = _playlist.length - 1;
    }
    await _audioPlayer.stop();
    await play();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _currentIndex = index;
    await _audioPlayer.stop();
    await play();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    // final enabled = shuffleMode == AudioServiceShuffleMode.all;
    // if (enabled) {
    // await _audioPlayer.shuffle();
    // }
    // playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
    // await _audioPlayer.setShuffleModeEnabled(enabled);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    _loopMode = repeatMode;
  }
}

class QueueState {
  static const QueueState empty =
      QueueState([], 0, AudioServiceRepeatMode.none);

  final List<MediaItem> queue;
  final int? queueIndex;
  final AudioServiceRepeatMode repeatMode;

  const QueueState(this.queue, this.queueIndex, this.repeatMode);

  bool get hasPrevious =>
      repeatMode != AudioServiceRepeatMode.none || (queueIndex ?? 0) > 0;

  bool get hasNext =>
      repeatMode != AudioServiceRepeatMode.none ||
      (queueIndex ?? 0) + 1 < queue.length;
}

class MediaLibrary {
  static const albumsRootId = 'albums';

  final items = <String, List<MediaItem>>{
    AudioService.browsableRootId: const [
      MediaItem(
        id: albumsRootId,
        title: "Albums",
        playable: false,
      ),
    ],
    albumsRootId: [
      MediaItem(
        id: 'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3',
        album: "Science Friday",
        title: "A Salute To Head-Scratching Science",
        artist: "Science Friday and WNYC Studios",
        duration: const Duration(milliseconds: 5739820),
        artUri: Uri.parse(
            'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
      ),
      MediaItem(
        id: 'https://s3.amazonaws.com/scifri-segments/scifri201711241.mp3',
        album: "Science Friday",
        title: "From Cat Rheology To Operatic Incompetence",
        artist: "Science Friday and WNYC Studios",
        duration: const Duration(milliseconds: 2856950),
        artUri: Uri.parse(
            'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
      ),
      MediaItem(
        id: 'https://s3.amazonaws.com/scifri-segments/scifri202011274.mp3',
        album: "Science Friday",
        title: "Laugh Along At Home With The Ig Nobel Awards",
        artist: "Science Friday and WNYC Studios",
        duration: const Duration(milliseconds: 1791883),
        artUri: Uri.parse(
            'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
      ),
    ],
  };
}

abstract class AudioPlayerHandler implements AudioHandler {
  Stream<QueueState> get queueState;
  Future<void> moveQueueItem(int currentIndex, int newIndex);
  ValueStream<double> get volume;
  Future<void> setVolume(double volume);
  ValueStream<double> get speed;
  Stream<Duration> get durationStream;
}
