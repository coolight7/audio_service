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

  // 播放列表
  final List<MediaItem> _playlist = [
    MediaItem(
        id: 'mengxingshifen_wubai.mp3',
        album: "梦醒时分",
        title: "梦醒时分",
        artist: "伍佰",
        duration: const Duration(milliseconds: 32359),
        artUri: Uri.parse(
            'https://img2.baidu.com/it/u=2692119690,2027500640&fm=253&fmt=auto&app=120&f=JPEG?w=661&h=429')),
    MediaItem(
        id: 'niwangqianzoubuyaohuitou_linsanqi.mp3',
        album: "你往前走不要回头",
        title: "你往前走不要回头",
        duration: const Duration(milliseconds: 31967),
        artist: "林三七",
        artUri: Uri.parse(
            'https://img1.baidu.com/it/u=3052138256,3214274550&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=500')),
    MediaItem(
        id: 'qinghua_zhouchuanxiong.mp3',
        album: "青花",
        title: "青花",
        artist: "周传雄",
        duration: const Duration(milliseconds: 25436),
        artUri: Uri.parse(
            'https://img2.baidu.com/it/u=3022312323,1267021894&fm=253&fmt=auto&app=120&f=JPEG?w=889&h=500')),
    MediaItem(
        id: 'tonghuazhen_chenyifaer.mp3',
        album: "童话镇",
        title: "童话镇",
        artist: "陈一发儿",
        duration: const Duration(milliseconds: 29825),
        artUri: Uri.parse(
            'https://img1.baidu.com/it/u=2532973369,265072396&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=500')),
    MediaItem(
        id: 'wodezhifeiji.mp3',
        album: "我的纸飞机",
        title: "我的纸飞机",
        artist: "GooGo/王只睿",
        duration: const Duration(milliseconds: 43461),
        artUri: Uri.parse(
            'https://img2.baidu.com/it/u=1100349303,2680199441&fm=253&fmt=auto&app=120&f=JPEG?w=799&h=500')),
    MediaItem(
        id: 'yi_qu_xiang_sai-ban_yang323.mp3',
        album: "一曲相思",
        title: "一曲相思",
        artist: "半阳",
        duration: const Duration(milliseconds: 37483),
        artUri: Uri.parse(
            'https://img1.baidu.com/it/u=690405603,3391326750&fm=253&fmt=auto&app=120&f=JPEG?w=889&h=500')),
  ];

  int _currentIndex = 0;
  bool _isLoading = false;
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
            bufferedPosition: _duration,
            updatePosition:
                await _audioPlayer.getCurrentPosition() as Duration));
        _isLoading = false;
      } else if (state == PlayerState.paused) {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          playing: false,
        ));
      } else if (state == PlayerState.stopped) {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          playing: false,
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
      await stop();
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
      ));
      mediaItem.add(_playlist[_currentIndex]);

      await _audioPlayer.play(AssetSource(_playlist[_currentIndex].id));
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
    playbackState.add(playbackState.value.copyWith());
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
    // 检查索引范围
    if (index == _currentIndex) {
      await _audioPlayer.stop();
    }
    _playlist.removeAt(index);
    if (_playlist.isNotEmpty) {
      if (_currentIndex > _playlist.length - 1) {
        _currentIndex = _playlist.length - 1;
      }
      play();
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
    await stop();
    await play();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_currentIndex - 1 >= 0) {
      _currentIndex--;
    } else {
      _currentIndex = _playlist.length - 1;
    }
    await stop();
    await play();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _currentIndex = index;
    await stop();
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
        id: 'https://www.joy127.com/url/108983.mp3',
        album: "三生三幸",
        title: "三生三幸",
        artist: "程响",
        duration: const Duration(milliseconds: 15307),
        artUri: Uri.parse(
            'https://joy127.jstools.net/link/pic?type=kugou&id=99fd95b96a63815a788687a13d74ff63'),
      ),
      MediaItem(
        id: 'https://stream.556600.com/AE/bishangguan_dengshenmejun.mp3',
        album: "壁上观",
        title: "壁上观",
        artist: "等什么君",
        duration: const Duration(milliseconds: 32150),
        artUri: Uri.parse(
            'https://img2.baidu.com/it/u=581948488,1876498694&fm=253&fmt=auto&app=120&f=JPEG?w=766&h=500'),
      ),
      MediaItem(
        id: 'https://www.joy127.com/url/109333.mp3',
        album: "人间烟火",
        title: "人间烟火",
        artist: "程响",
        duration: const Duration(milliseconds: 35664),
        artUri: Uri.parse(
            'https://img0.baidu.com/it/u=1267470360,95321030&fm=253&fmt=auto&app=120&f=JPEG?w=723&h=500'),
      ),
      MediaItem(
        id: 'https://stream.556600.com/AD/qinghua_zhouchuanxiong.mp3',
        album: "青花",
        title: "青花",
        artist: "周传雄",
        duration: const Duration(milliseconds: 25436),
        artUri: Uri.parse(
            'https://i0.hdslb.com/bfs/archive/eff3b8e4b76279c47327f3f913d126fdffedacd4.jpg'),
      ),
      MediaItem(
        id: 'https://stream.556600.com/AD/mengxingshifen_wubai.mp3',
        album: "梦醒时分",
        title: "梦醒时分",
        artist: "伍佰",
        duration: const Duration(milliseconds: 32359),
        artUri: Uri.parse(
            'https://i2.hdslb.com/bfs/archive/2026cc3e8635bb9b790a16d69a509061f25e1145.jpg'),
      ),
      MediaItem(
        id: 'https://stream.556600.com/AC/niwangqianzoubuyaohuitou_linsanqi.mp3',
        album: "你往前走不要回头",
        title: "你往前走不要回头",
        artist: "林三七",
        duration: const Duration(milliseconds: 31967),
        artUri: Uri.parse(
            'https://img0.baidu.com/it/u=1440398448,3982887716&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=500'),
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
}
