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

// ignore_for_file: public_member_api_docs

// This example demonstrates a simple video_player integration.
//
// To run this example, use:
//
// flutter run -t lib/example_video_player.dart

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

// You might want to provide this using dependency injection rather than a
// global variable.
late AudioPlayerHandler _audioHandler;

Future<void> main() async {
  _audioHandler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ryanheise.myapp.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Service Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({Key? key}) : super(key: key);

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();

    _controller = VideoPlayerController.asset('assets/video2.mp4',videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true))
      ..initialize().then((_) {
        _audioHandler.setVideoFunctions(
            _controller.play, _controller.pause, _controller.seekTo, () {
          _controller.seekTo(Duration.zero);
          _controller.pause();
        });

        // _controller = VideoPlayerController.network(
        //     'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
        //     videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true))
        //   ..initialize().then((_) {
        //     _audioHandler.setVideoFunctions(
        //         _controller.play, _controller.pause, _controller.seekTo, () {
        //       _controller.seekTo(Duration.zero);
        //       _controller.pause();
        //     });

        // So that our clients (the Flutter UI and the system notification) know
        // what state to display, here we set up our audio handler to broadcast all
        // playback state changes as they happen via playbackState...
        _audioHandler.initializeStreamController(_controller);
        _audioHandler.playbackState
            .addStream(_audioHandler.streamController.stream);

        // Ensure the first frame is shown after the video is initialized, even before the play button has been pressed.
        setState(() {});
      });
  }

  @override
  void dispose() {
    // Close the stream
    _audioHandler.streamController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Service Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Center(
              child: _controller.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    )
                  : Container(),
            ),
            // Play/pause/stop buttons.
            StreamBuilder<bool>(
              stream: _audioHandler.playbackState
                  .map((state) => state.playing)
                  .distinct(),
              builder: (context, snapshot) {
                final playing = snapshot.data ?? false;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _button(Icons.fast_rewind, _audioHandler.rewind),
                    if (playing)
                      _button(Icons.pause, _audioHandler.pause)
                    else
                      _button(Icons.play_arrow, _audioHandler.play),
                    _button(Icons.stop, _audioHandler.stop),
                    _button(Icons.fast_forward, _audioHandler.fastForward),
                  ],
                );
              },
            ),
            // Display the processing state.
            StreamBuilder<AudioProcessingState>(
              stream: _audioHandler.playbackState
                  .map((state) => state.processingState)
                  .distinct(),
              builder: (context, snapshot) {
                final processingState =
                    snapshot.data ?? AudioProcessingState.idle;
                return Text("Processing state: ${(processingState)}");
              },
            ),
          ],
        ),
      ),
    );
  }

  IconButton _button(IconData iconData, VoidCallback onPressed) => IconButton(
        icon: Icon(iconData),
        iconSize: 64.0,
        onPressed: onPressed,
      );
}

class MediaState {
  final MediaItem? mediaItem;
  final Duration position;

  MediaState(this.mediaItem, this.position);
}

/// An [AudioHandler] for playing a single item.
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  late StreamController<PlaybackState> streamController;
  bool stopIsClick = false;

  static final _item = MediaItem(
      id: 'video1.mp4',
      album: "video1.mp4",
      title: "video1.mp4",
      artist: "Science Friday and WNYC Studios",
      duration: const Duration(milliseconds: 5739820),
      artUri: Uri.parse(
          'https://media.wnyc.org/i/1400/1400/l/80/1/ScienceFriday_WNYCStudios_1400.jpg'),
      extras: {'mediaType': 'video'});

  Function? _videoPlay;
  Function? _videoPause;
  Function? _videoSeek;
  Function? _videoStop;

  void setVideoFunctions(
      Function play, Function pause, Function seek, Function stop) {
    _videoPlay = play;
    _videoPause = pause;
    _videoSeek = seek;
    _videoStop = stop;
    mediaItem.add(_item);
  }

  /// Initialise our audio handler.
  AudioPlayerHandler();

  // In this simple example, we handle only 4 actions: play, pause, seek and
  // stop. Any button press from the Flutter UI, notification, lock screen or
  // headset will be routed through to these 4 methods so that you can handle
  // your audio playback logic in one place.

  @override
  Future<void> play() async {
    stopIsClick = false;
    _videoPlay!();
  }

  @override
  Future<void> pause() async => _videoPause!();

  @override
  Future<void> seek(Duration position) async => _videoSeek!(position);

  @override
  Future<void> stop() async {
    stopIsClick = true;
    _videoStop!();
  }

  void initializeStreamController(
      VideoPlayerController? videoPlayerController) {
    bool _isPlaying() => videoPlayerController?.value.isPlaying ?? false;

    AudioProcessingState _processingState() {
      if (videoPlayerController == null) return AudioProcessingState.idle;
      if (videoPlayerController.value.isInitialized) {
        if (stopIsClick) {
          return AudioProcessingState.idle;
        } else {
          return AudioProcessingState.ready;
        }
      }
      return AudioProcessingState.idle;
    }

    void _addVideoEvent() {
      streamController.add(PlaybackState(
        controls: [
          MediaControl.rewind,
          if (_isPlaying()) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: _processingState(),
        playing: _isPlaying(),
        updatePosition: videoPlayerController?.value.position ?? Duration.zero,
        bufferedPosition:
            videoPlayerController?.value.duration ?? Duration.zero,
        speed: videoPlayerController?.value.playbackSpeed ?? 1.0,
      ));
    }

    void startStream() {
      videoPlayerController?.addListener(_addVideoEvent);
    }

    void stopStream() {
      videoPlayerController?.removeListener(_addVideoEvent);
      streamController.close();
    }

    streamController = StreamController<PlaybackState>(
        onListen: startStream,
        onPause: stopStream,
        onResume: startStream,
        onCancel: stopStream);
  }
}
