// fqapp/native_player: the AVPlayer-backed media plugin.
//
// Video is rendered straight into the Flutter external texture: the embedding
// hands us a SurfaceTexture, we turn it into a surface id and point AVPlayer at
// it. Audio uses the same player without a surface. Every stream is opened
// through the Rust core (loopback cleartext with CENC decryption and the CDN
// auth headers the player cannot send itself), which is what the desktop player
// does too.
//
// The Dart contract (lib/services/native_player.dart) is the only spec that
// matters here:
//   * events are {playerId, type, value?} on fqapp/native_player/events, and the
//     event channel is never allowed to fail - every error is a data event;
//   * create replies {playerId, textureId} immediately and finishes asynchronously
//     with a 'created' event (25 s budget);
//   * player ids are never reused (Dart keeps a 30 s tombstone for old ids);
//   * draw-over-apps ("悬浮窗") is not available on HarmonyOS: the reporting
//     methods return the degraded values Dart already handles, and the real
//     pip-style floating window is a later milestone.
import {
  Any,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler,
  SurfaceTextureEntry,
  SurfaceTextureRegistryEntry,
  TextureRegistry,
} from '@ohos/flutter_ohos';
import media from '@ohos.multimedia.media';
import avSession from '@ohos.multimedia.avsession';
import wantAgent from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import common from '@ohos.app.ability.common';
import audio from '@ohos.multimedia.audio';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import fqNative from 'libfq_native.so';
import { AbilityContextHolder } from './AbilityContextHolder';

const METHOD_CHANNEL = 'fqapp/native_player';
const EVENT_CHANNEL = 'fqapp/native_player/events';
const AV_SESSION_TAG = 'fqapp_listen';
const BUNDLE_NAME = 'com.shijinpu.fqapp';
const ABILITY_NAME = 'EntryAbility';
const TAG = 'fqapp_player';
/// Dart throttles position updates itself; staying below it keeps the sliders
/// smooth without flooding the platform channel.
const POSITION_EMIT_INTERVAL_MS = 250;

/// The Rust bridge replies with {"id","url"} or {"error","kind","status"}.
interface MediaOpenReply {
  id?: string;
  url?: string;
  error?: string;
  kind?: string;
  status?: number;
}

/// Swallows the reply of a plugin -> Dart call (the Dart side has no answer we
/// can use); without a callback the engine would log an unhandled reply.
class SilentMethodResult implements MethodResult {
  success: (result: Any) => void = (result: Any): void => {};
  error: (errorCode: string, errorMessage: string, errorDetails: Any) => void =
    (errorCode: string, errorMessage: string, errorDetails: Any): void => {};
  notImplemented: () => void = (): void => {};
}

class PlayerEntry {
  playerId: number = 0;
  textureId: number = -1;
  surfaceId: string = '';
  audioOnly: boolean = false;
  player: media.AVPlayer | null = null;
  texture: SurfaceTextureEntry | null = null;
  mediaSessionId: string = '';
  prepared: boolean = false;
  completed: boolean = false;
  pendingPlay: boolean = false;
  playWhenReady: boolean = false;
  disposed: boolean = false;
  /// Set while a seek is in flight: AVPlayer may still deliver pre-seek
  /// timeUpdate callbacks and Dart would paint the old position over its own
  /// optimistic update.
  seekTargetMs: number = -1;
  lastEmittedPositionMs: number = -1;
  lastEmittedMs: number = 0;
  rate: number = 1.0;
  volume: number = 1.0;
}

export default class FqPlayerPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private channel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private events: EventSink | null = null;
  private registry: TextureRegistry | null = null;
  private appContext: common.Context | null = null;
  private entries: Map<number, PlayerEntry> = new Map();
  private nextPlayerId: number = 0;
  private session: avSession.AVSession | null = null;
  private sessionBound: boolean = false;
  private foregroundActive: boolean = false;
  private stopRequested: boolean = false;
  /// Serialises foreground start/stop. The Dart side re-snapshots the session on
  /// every progress tick, and stop/start arrive back to back when a session is
  /// replaced. Overlapping work races two system services: createAVSession
  /// reports `session is existed` (6600101) while the previous destroy is still
  /// in flight, and startBackgroundRunning reports 9800005 because the app
  /// "has applied for a continuous task". Chaining keeps them ordered.
  private foregroundQueue: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return 'FqPlayerPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.registry = binding.getTextureRegistry();
    this.appContext = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
    this.channel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.events = null;
    if (this.eventChannel !== null) {
      this.eventChannel.setStreamHandler(null);
      this.eventChannel = null;
    }
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    const ids: number[] = Array.from(this.entries.keys());
    for (const id of ids) {
      this.disposeEntryById(id);
    }
    this.enqueueForeground(async () => {
      await this.doStopForeground();
    });
  }

  // ---- event channel -------------------------------------------------------

  onListen(args: Any, events: EventSink): void {
    this.events = events;
  }

  onCancel(args: Any): void {
    this.events = null;
  }

  // ---- method channel ------------------------------------------------------

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const method: string = call.method;
    if (method === 'create') {
      this.handleCreate(call, result);
      return;
    }
    if (method === 'startListenForeground') {
      this.handleStartForeground(call, result);
      return;
    }
    if (method === 'stopListenForeground') {
      this.handleStopForeground(result);
      return;
    }
    if (method === 'canDrawOverlays') {
      // HarmonyOS only exposes picture-in-picture to ordinary apps; the Dart
      // side implements the soft degradation around this gate.
      result.success(false);
      return;
    }
    if (method === 'requestOverlayPermission') {
      result.success(false);
      return;
    }
    if (method === 'allocateFloatingOwner') {
      result.success(1);
      return;
    }
    if (method === 'startFloating' || method === 'showFloating' || method === 'updateFloating'
      || method === 'stopFloating' || method === 'swapFloatingPlayer') {
      result.success(null);
      return;
    }
    if (method === 'gestureLevels') {
      result.success(null);
      return;
    }
    if (method === 'setScreenBrightness' || method === 'resetScreenBrightness'
      || method === 'setMediaVolume') {
      result.success(null);
      return;
    }
    if (method === 'getPlaybackSettings') {
      const settings: Map<string, Object> = new Map();
      settings.set('volume', 1.0);
      settings.set('rate', 1.0);
      result.success(settings);
      return;
    }
    if (method === 'setKeepScreenOn') {
      this.applyKeepScreenOn(this.readBool(call, 'on', false));
      result.success(null);
      return;
    }
    if (method === 'play') {
      this.handlePlay(call, result);
      return;
    }
    if (method === 'pause') {
      this.handlePause(call, result);
      return;
    }
    if (method === 'seek') {
      this.handleSeek(call, result);
      return;
    }
    if (method === 'setVolume') {
      this.handleSetVolume(call, result);
      return;
    }
    if (method === 'setRate') {
      this.handleSetRate(call, result);
      return;
    }
    if (method === 'dispose') {
      const entry = this.entryOf(call);
      if (entry !== null) {
        entry.disposed = true;
        this.entries.delete(entry.playerId);
        this.releaseEntry(entry);
      }
      result.success(null);
      return;
    }
    result.notImplemented();
  }

  // ---- creation ------------------------------------------------------------

  private handleCreate(call: MethodCall, result: MethodResult): void {
    const cdnUrl = this.readString(call, 'cdnUrl', '');
    if (cdnUrl.length === 0) {
      result.error('INVALID_ARGUMENT', 'Missing required argument: cdnUrl', null);
      return;
    }
    const keyArgument: Any = call.argument('keyHex');
    if (keyArgument === undefined || keyArgument === null) {
      result.error('INVALID_ARGUMENT', 'Missing required argument: keyHex', null);
      return;
    }
    const keyHex = this.readString(call, 'keyHex', '');
    const audioOnly = this.readBool(call, 'audioOnly', false);
    const startPositionMs = this.readInt(call, 'startPositionMs', 0);

    const entry = new PlayerEntry();
    this.nextPlayerId = this.nextPlayerId + 1;
    entry.playerId = this.nextPlayerId;
    entry.audioOnly = audioOnly;
    this.entries.set(entry.playerId, entry);

    // Android replies before the player exists; Dart is built around that and
    // finishes creation from the 'created' event.
    const reply: Map<string, Object> = new Map();
    reply.set('playerId', entry.playerId);
    reply.set('textureId', -1);
    result.success(reply);

    this.openEntry(entry, cdnUrl, keyHex, startPositionMs).catch((error: Object) => {
      this.failCreation(entry, this.describeError(error));
    });
  }

  private async openEntry(entry: PlayerEntry, cdnUrl: string, keyHex: string,
    startPositionMs: number): Promise<void> {
    const registry = this.registry;
    if (registry === null) {
      throw new Error('texture registry unavailable');
    }

    const texture: SurfaceTextureEntry = registry.registerTexture(registry.getTextureId());
    entry.texture = texture;
    entry.textureId = texture.getTextureId();
    if (!entry.audioOnly) {
      // getSurfaceId() is the numeric id the renderer already produced; the
      // native-window lookup stays as the fallback for engine changes.
      const registeredSurfaceId: number = texture.getSurfaceId();
      if (registeredSurfaceId > 0) {
        entry.surfaceId = registeredSurfaceId.toString();
      } else {
        const nativeEntry = texture as SurfaceTextureRegistryEntry;
        const pointer: bigint = nativeEntry.getNativeWindowPtr();
        entry.surfaceId = fqNative.getSurfaceId(pointer) as string;
      }
    }
    console.info(`${TAG} create id=${entry.playerId} texture=${entry.textureId} surface=${entry.surfaceId} audioOnly=${entry.audioOnly}`);

    // Rust core: signed CDN fetch + CENC decryption + loopback clear stream.
    // The clear cookies/headers never leave the process.
    const bridgeReply: string = fqNative.openMediaSource(cdnUrl, keyHex) as string;
    const opened: MediaOpenReply = JSON.parse(bridgeReply) as MediaOpenReply;
    if (opened.error !== undefined && opened.error.length > 0) {
      throw new Error(opened.error);
    }
    const playbackUrl: string = opened.url === undefined ? '' : opened.url;
    if (playbackUrl.length === 0) {
      throw new Error('媒体地址不可用，请重试');
    }
    entry.mediaSessionId = opened.id === undefined ? '' : opened.id;

    if (entry.disposed) {
      this.closeMediaSession(entry);
      throw new Error('player disposed during create');
    }

    const player = await media.createAVPlayer();
    if (entry.disposed) {
      player.release().catch((error: BusinessError) => {
        console.warn(`${TAG} release aborted player: ${error.message}`);
      });
      this.closeMediaSession(entry);
      return;
    }
    entry.player = player;
    this.bindPlayerEvents(entry, player);

    try {
      player.url = playbackUrl;
    } catch (error) {
      throw new Error(this.describeError(error));
    }
    entry.seekTargetMs = startPositionMs > 0 ? startPositionMs : -1;
  }

  private bindPlayerEvents(entry: PlayerEntry, player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      if (entry.disposed) {
        return;
      }
      console.info(`${TAG} id=${entry.playerId} state=${state} reason=${reason}`);
      if (state === 'initialized') {
        this.attachOutput(entry, player);
        player.prepare().catch((error: BusinessError) => {
          this.failPlayback(entry, `prepare failed: ${error.message}`, error.code);
        });
        return;
      }
      if (state === 'prepared') {
        this.onPrepared(entry, player);
        return;
      }
      if (state === 'playing') {
        entry.playWhenReady = true;
        this.sendEvent(entry.playerId, 'playing', true);
        this.sendEvent(entry.playerId, 'playWhenReady', true);
        this.syncSessionState(true, entry.rate);
        return;
      }
      if (state === 'paused') {
        this.sendEvent(entry.playerId, 'playing', false);
        this.syncSessionState(false, entry.rate);
        return;
      }
      if (state === 'completed') {
        entry.completed = true;
        entry.playWhenReady = false;
        this.sendEvent(entry.playerId, 'playing', false);
        this.sendEvent(entry.playerId, 'completed', true);
        this.syncSessionState(false, entry.rate);
        return;
      }
      if (state === 'stopped' || state === 'released' || state === 'idle') {
        this.sendEvent(entry.playerId, 'playing', false);
      }
    });

    player.on('error', (error: BusinessError) => {
      if (entry.disposed) {
        return;
      }
      console.error(`${TAG} id=${entry.playerId} error ${error.code}: ${error.message}`);
      const code: number = typeof error.code === 'number' ? error.code : -1;
      this.failPlayback(entry, error.message, code);
    });

    player.on('startRenderFrame', () => {
      if (entry.disposed) {
        return;
      }
      this.sendEvent(entry.playerId, 'firstFrame', true);
    });

    player.on('videoSizeChange', (width: number, height: number) => {
      if (entry.disposed || width <= 0 || height <= 0) {
        return;
      }
      const event: Map<string, Object> = new Map();
      event.set('playerId', entry.playerId);
      event.set('type', 'videoSize');
      event.set('width', width);
      event.set('height', height);
      event.set('rotationCorrection', 0);
      this.events?.success(event);
    });

    player.on('durationUpdate', (duration: number) => {
      if (entry.disposed || duration <= 0) {
        return;
      }
      this.sendEvent(entry.playerId, 'duration', Math.trunc(duration));
    });

    player.on('timeUpdate', (position: number) => {
      if (entry.disposed || entry.seekTargetMs >= 0) {
        return;
      }
      const now = Date.now();
      if (position === entry.lastEmittedPositionMs && now - entry.lastEmittedMs < 1000) {
        return;
      }
      if (now - entry.lastEmittedMs < POSITION_EMIT_INTERVAL_MS) {
        return;
      }
      entry.lastEmittedPositionMs = position;
      entry.lastEmittedMs = now;
      this.sendEvent(entry.playerId, 'position', Math.trunc(position));
    });

    player.on('seekDone', (position: number) => {
      if (entry.disposed) {
        return;
      }
      entry.seekTargetMs = -1;
      entry.completed = false;
      entry.lastEmittedPositionMs = position;
      entry.lastEmittedMs = Date.now();
      this.sendEvent(entry.playerId, 'position', Math.trunc(position));
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (entry.disposed) {
        return;
      }
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.sendEvent(entry.playerId, 'buffering', true);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.sendEvent(entry.playerId, 'buffering', false);
      }
    });

    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (entry.disposed) {
        return;
      }
      if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
        // Dart pauses and drops the foreground session itself; the player must
        // not decide that on its own or the two states disagree.
        this.invokeDart('onAudioBecomingNoisy', new Map<string, Object>());
      }
    });
  }

  private attachOutput(entry: PlayerEntry, player: media.AVPlayer): void {
    if (!entry.audioOnly && entry.surfaceId.length > 0) {
      try {
        player.surfaceId = entry.surfaceId;
      } catch (error) {
        console.error(`${TAG} surface attach failed: ${this.describeError(error)}`);
      }
    }
    if (entry.audioOnly) {
      try {
        const rendererInfo: audio.AudioRendererInfo = {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0,
        };
        player.audioRendererInfo = rendererInfo;
      } catch (error) {
        console.warn(`${TAG} audioRendererInfo: ${this.describeError(error)}`);
      }
    }
  }

  private onPrepared(entry: PlayerEntry, player: media.AVPlayer): void {
    entry.prepared = true;
    try {
      player.loop = false;
    } catch (error) {
      console.warn(`${TAG} loop assign: ${this.describeError(error)}`);
    }
    const startPosition = entry.seekTargetMs;
    if (startPosition > 0) {
      try {
        player.seek(startPosition, media.SeekMode.SEEK_CLOSEST);
      } catch (error) {
        entry.seekTargetMs = -1;
        console.warn(`${TAG} start position seek: ${this.describeError(error)}`);
      }
    }
    if (entry.pendingPlay) {
      entry.pendingPlay = false;
      player.play().catch((error: BusinessError) => {
        this.failPlayback(entry, `play failed: ${error.message}`, error.code);
      });
    }
    // Dart treats 'created' as "the texture is live"; sending it after prepare
    // matches the Android plugin, which reports the event once the player has a
    // prepared source.
    this.sendEvent(entry.playerId, 'created', entry.textureId);
  }

  // ---- playback controls ---------------------------------------------------

  private handlePlay(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    if (entry === null) {
      result.success(null);
      return;
    }
    entry.playWhenReady = true;
    this.sendEvent(entry.playerId, 'playWhenReady', true);
    const player = entry.player;
    if (player === null || !entry.prepared) {
      entry.pendingPlay = true;
      result.success(null);
      return;
    }
    if (entry.completed) {
      // ExoPlayer restarts from zero here; without the seek + explicit events
      // Dart immediately treats the replay as finished and skips the episode.
      entry.completed = false;
      entry.seekTargetMs = 0;
      try {
        player.seek(0, media.SeekMode.SEEK_CLOSEST);
      } catch (error) {
        entry.seekTargetMs = -1;
      }
      this.sendEvent(entry.playerId, 'position', 0);
      this.sendEvent(entry.playerId, 'completed', false);
    }
    player.play().catch((error: BusinessError) => {
      this.failPlayback(entry, `play failed: ${error.message}`, error.code);
    });
    result.success(null);
  }

  private handlePause(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    if (entry === null) {
      result.success(null);
      return;
    }
    entry.playWhenReady = false;
    entry.pendingPlay = false;
    this.sendEvent(entry.playerId, 'playWhenReady', false);
    const player = entry.player;
    if (player !== null && entry.prepared) {
      player.pause().catch((error: BusinessError) => {
        console.warn(`${TAG} pause: ${error.message}`);
      });
    }
    this.syncSessionState(false, entry.rate);
    result.success(null);
  }

  private handleSeek(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    if (entry === null) {
      result.success(null);
      return;
    }
    const positionMs = this.readInt(call, 'positionMs', 0);
    const player = entry.player;
    if (player !== null && entry.prepared) {
      entry.seekTargetMs = positionMs;
      entry.completed = false;
      try {
        player.seek(positionMs, media.SeekMode.SEEK_CLOSEST);
      } catch (error) {
        entry.seekTargetMs = -1;
        console.warn(`${TAG} seek: ${this.describeError(error)}`);
      }
    }
    result.success(null);
  }

  private handleSetVolume(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    if (entry !== null) {
      let volume = this.readDouble(call, 'volume', 1.0);
      if (volume < 0) {
        volume = 0;
      }
      if (volume > 1) {
        volume = 1;
      }
      entry.volume = volume;
      const player = entry.player;
      if (player !== null) {
        try {
          player.setVolume(volume);
        } catch (error) {
          console.warn(`${TAG} setVolume: ${this.describeError(error)}`);
        }
      }
    }
    result.success(null);
  }

  private handleSetRate(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    if (entry !== null) {
      let rate = this.readDouble(call, 'rate', 1.0);
      if (!(rate > 0)) {
        rate = 1.0;
      }
      if (rate < 0.125) {
        rate = 0.125;
      }
      if (rate > 4) {
        rate = 4;
      }
      entry.rate = rate;
      const player = entry.player;
      if (player !== null) {
        try {
          player.setPlaybackRate(rate);
        } catch (error) {
          console.warn(`${TAG} setRate: ${this.describeError(error)}`);
        }
      }
      this.syncSessionState(entry.playWhenReady, rate);
    }
    result.success(null);
  }

  private applyKeepScreenOn(on: boolean): void {
    const context = this.abilityContext() ?? this.appContext;
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window) => {
      return mainWindow.setWindowKeepScreenOn(on);
    }).catch((error: BusinessError) => {
      console.warn(`${TAG} keepScreenOn: ${error.message}`);
    });
  }

  // ---- foreground session (continuous task + AVSession) --------------------

  private handleStartForeground(call: MethodCall, result: MethodResult): void {
    const title = this.readString(call, 'title', '');
    const episode = this.readString(call, 'episode', '');
    const playing = this.readBool(call, 'playing', false);
    const positionMs = this.readInt(call, 'positionMs', 0);
    const durationMs = this.readInt(call, 'durationMs', 0);
    const speed = this.readDouble(call, 'speed', 1.0);
    // Reply first: Dart has no timeout on this call but it must never hang, and
    // the foreground work is a snapshot, not something the caller waits on.
    result.success(null);
    this.enqueueForeground(async () => {
      await this.applyForeground(title, episode, playing, positionMs, durationMs, speed);
    });
  }

  /// Runs foreground work in arrival order, swallowing failures into the log:
  /// a broken media session must not abort the queue for later calls.
  private enqueueForeground(work: () => Promise<void>): void {
    this.foregroundQueue = this.foregroundQueue
      .then(work)
      .catch((error: Object) => {
        console.error(`${TAG} foreground task: ${this.describeError(error)}`);
      });
  }

  private async applyForeground(title: string, episode: string, playing: boolean,
    positionMs: number, durationMs: number, speed: number): Promise<void> {
    const context = this.abilityContext();
    if (context === null) {
      console.error(`${TAG} startListenForeground without a UIAbility context`);
      return;
    }
    this.stopRequested = false;
    await this.startContinuousTask(context);
    const session = await this.ensureSession(context);
    if (session === null || this.stopRequested) {
      return;
    }
    await this.applySessionSnapshot(session, title, episode, playing, positionMs, durationMs, speed);
  }

  private async startContinuousTask(context: common.UIAbilityContext): Promise<void> {
    if (this.foregroundActive) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: BUNDLE_NAME,
            abilityName: ABILITY_NAME,
          },
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent,
      );
      this.foregroundActive = true;
      console.info(`${TAG} continuous task started`);
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code === 9800005) {
        // "The application has applied for a continuous task": a previous
        // request is still pending with the background task service. Treat it
        // as ours and keep the bookkeeping in sync instead of leaking a false
        // negative that makes the next stop skip stopBackgroundRunning.
        this.foregroundActive = true;
        console.info(`${TAG} continuous task already requested`);
        return;
      }
      console.error(`${TAG} startBackgroundRunning failed ${failure.code}: ${failure.message}`);
    }
  }

  private async ensureSession(context: common.UIAbilityContext): Promise<avSession.AVSession | null> {
    const existing = this.session;
    if (existing !== null) {
      return existing;
    }
    try {
      const session = await avSession.createAVSession(context, AV_SESSION_TAG, 'audio');
      this.session = session;
      this.bindSessionControls(session);
      await session.activate();
      return session;
    } catch (error) {
      const failure = error as BusinessError;
      console.error(`${TAG} createAVSession failed ${failure.code}: ${failure.message}`);
      return null;
    }
  }

  private bindSessionControls(session: avSession.AVSession): void {
    if (this.sessionBound) {
      return;
    }
    this.sessionBound = true;
    session.on('play', () => {
      this.invokeDart('onNotificationAction', this.actionArgs('play', -1));
    });
    session.on('pause', () => {
      this.invokeDart('onNotificationAction', this.actionArgs('pause', -1));
    });
    session.on('stop', () => {
      this.invokeDart('onNotificationAction', this.actionArgs('stop', -1));
    });
    session.on('playNext', () => {
      this.invokeDart('onNotificationAction', this.actionArgs('next', -1));
    });
    session.on('playPrevious', () => {
      this.invokeDart('onNotificationAction', this.actionArgs('prev', -1));
    });
    session.on('seek', (time: number) => {
      this.invokeDart('onNotificationAction', this.actionArgs('seekTo', Math.trunc(time)));
    });
  }

  private async applySessionSnapshot(session: avSession.AVSession, title: string, episode: string,
    playing: boolean, positionMs: number, durationMs: number, speed: number): Promise<void> {
    try {
      const metadata: avSession.AVMetadata = {
        assetId: title.length > 0 ? title : 'fqapp-listen',
        title: title,
        artist: episode,
      };
      if (durationMs > 0) {
        metadata.duration = durationMs;
      }
      await session.setAVMetadata(metadata);
      const playbackState: avSession.AVPlaybackState = {
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: speed > 0 ? speed : 1.0,
        position: { elapsedTime: positionMs, updateTime: Date.now() },
      };
      await session.setAVPlaybackState(playbackState);
      await session.activate();
    } catch (error) {
      const failure = error as BusinessError;
      console.error(`${TAG} setAVMetadata failed ${failure.code}: ${failure.message}`);
    }
  }

  private syncSessionState(playing: boolean, speed: number): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: speed > 0 ? speed : 1.0,
    };
    session.setAVPlaybackState(playbackState).catch((error: BusinessError) => {
      console.warn(`${TAG} setAVPlaybackState: ${error.message}`);
    });
  }

  private handleStopForeground(result: MethodResult): void {
    this.stopRequested = true;
    result.success(null);
    this.enqueueForeground(async () => {
      await this.doStopForeground();
    });
  }

  private async doStopForeground(): Promise<void> {
    const session = this.session;
    this.session = null;
    this.sessionBound = false;
    if (session !== null) {
      // Await destroy: the session lives in a system service, and a following
      // createAVSession with the same tag fails with 6600101 while the old one
      // is still being torn down.
      try {
        await session.destroy();
      } catch (error) {
        console.warn(`${TAG} destroy session: ${this.describeError(error)}`);
      }
    }
    const context = this.abilityContext() ?? this.appContext;
    if (this.foregroundActive && context !== null) {
      this.foregroundActive = false;
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        console.info(`${TAG} continuous task stopped`);
      } catch (error) {
        console.warn(`${TAG} stopBackgroundRunning: ${this.describeError(error)}`);
      }
    }
  }

  // ---- lifecycle helpers ---------------------------------------------------

  private releaseEntry(entry: PlayerEntry): void {
    const player = entry.player;
    entry.player = null;
    if (player !== null) {
      player.release().then(() => {
        console.info(`${TAG} player released id=${entry.playerId}`);
      }).catch((error: BusinessError) => {
        console.warn(`${TAG} release: ${error.message}`);
      });
    }
    const texture = entry.texture;
    entry.texture = null;
    if (texture !== null) {
      this.registry?.unregisterTexture(texture.getTextureId());
      texture.release();
    }
    this.closeMediaSession(entry);
  }

  private closeMediaSession(entry: PlayerEntry): void {
    const sessionId = entry.mediaSessionId;
    if (sessionId.length === 0) {
      return;
    }
    entry.mediaSessionId = '';
    try {
      fqNative.closeMediaSource(sessionId);
    } catch (error) {
      console.warn(`${TAG} closeMediaSource: ${this.describeError(error)}`);
    }
  }

  private disposeEntryById(playerId: number): void {
    const entry = this.entries.get(playerId);
    if (entry === undefined) {
      return;
    }
    this.entries.delete(playerId);
    entry.disposed = true;
    this.releaseEntry(entry);
  }

  private failCreation(entry: PlayerEntry, message: string): void {
    if (entry.disposed) {
      return;
    }
    entry.disposed = true;
    this.entries.delete(entry.playerId);
    this.releaseEntry(entry);
    console.error(`${TAG} create failed id=${entry.playerId}: ${message}`);
    this.sendError(entry.playerId, message, -1);
  }

  private failPlayback(entry: PlayerEntry, message: string, code: number): void {
    this.sendEvent(entry.playerId, 'playing', false);
    this.sendEvent(entry.playerId, 'playWhenReady', false);
    this.sendError(entry.playerId, message, code);
  }

  // ---- plumbing ------------------------------------------------------------

  private entryOf(call: MethodCall): PlayerEntry | null {
    const rawId: Any = call.argument('id');
    const playerId = rawId as number;
    if (typeof playerId !== 'number') {
      return null;
    }
    const entry = this.entries.get(Math.trunc(playerId));
    if (entry === undefined) {
      return null;
    }
    return entry;
  }

  private readString(call: MethodCall, key: string, fallback: string): string {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const text = value as string;
    if (typeof text !== 'string') {
      return fallback;
    }
    return text;
  }

  private readBool(call: MethodCall, key: string, fallback: boolean): boolean {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const flag = value as boolean;
    return typeof flag === 'boolean' ? flag : fallback;
  }

  private readInt(call: MethodCall, key: string, fallback: number): number {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const raw = value as number;
    if (typeof raw !== 'number' || !Number.isFinite(raw)) {
      return fallback;
    }
    return Math.trunc(raw);
  }

  private readDouble(call: MethodCall, key: string, fallback: number): number {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const raw = value as number;
    if (typeof raw !== 'number' || !Number.isFinite(raw)) {
      return fallback;
    }
    return raw;
  }

  private abilityContext(): common.UIAbilityContext | null {
    const context = AbilityContextHolder.context;
    if (context !== null) {
      return context;
    }
    const application = this.appContext;
    if (application === null) {
      return null;
    }
    return application as common.UIAbilityContext;
  }

  private sendEvent(playerId: number, type: string, value: Object): void {
    const sink = this.events;
    if (sink === null) {
      return;
    }
    const event: Map<string, Object> = new Map();
    event.set('playerId', playerId);
    event.set('type', type);
    event.set('value', value);
    sink.success(event);
  }

  private sendError(playerId: number, message: string, code: number): void {
    const value: Map<string, Object> = new Map();
    value.set('message', message);
    if (code > 0) {
      value.set('errorCode', code);
    }
    this.sendEvent(playerId, 'error', value);
  }

  private actionArgs(action: string, positionMs: number): Map<string, Object> {
    const args: Map<string, Object> = new Map();
    args.set('action', action);
    if (positionMs >= 0) {
      args.set('positionMs', positionMs);
    }
    return args;
  }

  private invokeDart(method: string, args: Any): void {
    const channel = this.channel;
    if (channel === null) {
      return;
    }
    channel.invokeMethod(method, args, new SilentMethodResult());
  }

  private describeError(error: Object): string {
    const failure = error as BusinessError;
    if (failure !== null && failure !== undefined) {
      const code = failure.code;
      const message = failure.message;
      if (message !== undefined && message.length > 0) {
        return code !== undefined ? `${code}: ${message}` : message;
      }
    }
    return `${error}`;
  }
}
