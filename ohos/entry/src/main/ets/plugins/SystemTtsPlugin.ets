// fqapp/system_tts: the HarmonyOS system text-to-speech backend.
//
// The Dart side (lib/services/system_tts.dart) owns the reading state machine:
// it splits chapters into sentences, keeps a two-deep queue and advances on our
// events. This plugin is therefore deliberately small - it plays the sentence
// it is given and reports start/done/error. The event payloads use Maps so that
// StandardMessageCodec hands Dart real ints and strings.
//
// Contract notes (kept in sync with system_tts.dart):
//   * the event channel is never allowed to fail: errors are data events, a
//     channel error would tear down the whole TTS session on the Dart side;
//   * the engine list must never be empty, otherwise the settings page hides
//     the whole engine/rate section;
//   * HarmonyOS has no engine-enumeration, pause, progress or audio-focus APIs
//     for TTS, so those capabilities degrade to stop/ignore and the range
//     highlight falls back to the Dart side's own pacing.
import textToSpeech from '@hms.ai.textToSpeech';
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
} from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';

const METHOD_CHANNEL = 'fqapp/system_tts';
const EVENT_CHANNEL = 'fqapp/system_tts_events';
const DOMAIN: number = 0xF0A0;
const TAG = 'fqapp_system_tts';

/// Longest sentence Dart hands us; the engine allows 10000 characters, this is
/// only a guard against a runaway caller.
const MAX_TEXT_LENGTH = 4000;

/// What `initialize` returns: Dart clamps it to 2..300 and uses it as the
/// per-utterance character budget. Matches the Android plugin's answer.
const MAX_UTTERANCE_LENGTH = 4000;

/// Timbre ids from CreateEngineParams: 13 is the bundled Ling Xiaoshan female
/// voice, 0 the default female voice. 21 (male) and 8 (English) must be
/// downloaded first, so they are not offered in the engine list.
const PERSON_LING_XIAOSHAN = 13;
const PERSON_DEFAULT = 0;
const DEFAULT_PERSON = PERSON_LING_XIAOSHAN;
const ENGINE_PREFIX = 'ohos.tts.person.';

class Utterance {
  dartId: string = '';
  requestId: string = '';
  text: string = '';
}

/// The listener has to be a stable object for the whole engine lifetime.
class SpeechListener implements textToSpeech.SpeakListener {
  private readonly plugin: SystemTtsPlugin;

  constructor(plugin: SystemTtsPlugin) {
    this.plugin = plugin;
  }

  onStart(requestId: string, response: textToSpeech.StartResponse): void {
    this.plugin.handleStart(requestId);
  }

  onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    this.plugin.handleComplete(requestId, response.type);
  }

  onStop(requestId: string, response: textToSpeech.StopResponse): void {
    // Only fired for our own stop()/pause()/shutdown(); the Dart side already
    // reset its queue in those cases, so there is nothing to report.
    hilog.debug(DOMAIN, TAG, 'engine stopped requestId=%{public}s type=%{public}d',
      requestId, response.type);
  }

  onError(requestId: string, errorCode: number, errorMessage: string): void {
    this.plugin.handleError(requestId, errorCode, errorMessage);
  }
}

export default class SystemTtsPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private channel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private events: EventSink | null = null;
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private person: number = -1;
  private queue: Utterance[] = [];
  private current: Utterance | null = null;
  private nextRequestSerial: number = 0;
  private rate: number = 1.0;
  private volume: number = 1.0;

  getUniqueClassName(): string {
    return 'SystemTtsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
    this.channel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.releaseEngine();
    this.events = null;
    if (this.eventChannel !== null) {
      this.eventChannel.setStreamHandler(null);
      this.eventChannel = null;
    }
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  // ---- EventChannel.StreamHandler -----------------------------------------

  onListen(args: Any, events: EventSink): void {
    this.events = events;
  }

  onCancel(args: Any): void {
    this.events = null;
  }

  // ---- MethodCallHandler ---------------------------------------------------

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const method = call.method;
    if (method === 'engines') {
      this.handleEngines(result);
      return;
    }
    if (method === 'initialize') {
      this.handleInitialize(call, result);
      return;
    }
    if (method === 'speak') {
      this.handleSpeak(call, result);
      return;
    }
    if (method === 'stop' || method === 'pause') {
      // HarmonyOS has no pause for TTS: pause and stop both release playback.
      // The Dart side resets its queue after either call.
      this.stopPlayback();
      result.success(null);
      return;
    }
    if (method === 'shutdown') {
      this.stopPlayback();
      this.releaseEngine();
      result.success(null);
      return;
    }
    if (method === 'setVolume') {
      this.volume = this.readDouble(call, 'volume', this.volume);
      // The offline engine has no per-app volume control; system volume wins.
      result.success(null);
      return;
    }
    if (method === 'setRate') {
      this.rate = this.readDouble(call, 'rate', this.rate);
      result.success(null);
      return;
    }
    if (method === 'getPlaybackSettings') {
      const settings: Map<string, Object> = new Map();
      settings.set('volume', this.volume);
      settings.set('rate', this.rate);
      result.success(settings);
      return;
    }
    if (method === 'settings') {
      result.error('unsupported',
        'HarmonyOS 未提供朗读引擎设置页，可在系统设置中调整音量', null);
      return;
    }
    result.notImplemented();
  }

  private handleEngines(result: MethodResult): void {
    const engines: Array<Map<string, Object>> = [];
    engines.push(this.describeEngine(PERSON_LING_XIAOSHAN, '系统朗读（聆小珊）'));
    engines.push(this.describeEngine(PERSON_DEFAULT, '系统朗读（默认女声）'));
    const reply: Map<string, Object> = new Map();
    reply.set('engines', engines);
    reply.set('defaultEngine', `${ENGINE_PREFIX}${DEFAULT_PERSON}`);
    result.success(reply);
  }

  private describeEngine(person: number, label: string): Map<string, Object> {
    const entry: Map<string, Object> = new Map();
    entry.set('package', `${ENGINE_PREFIX}${person}`);
    entry.set('label', label);
    return entry;
  }

  private handleInitialize(call: MethodCall, result: MethodResult): void {
    this.rate = this.readDouble(call, 'rate', this.rate);
    this.volume = this.readDouble(call, 'volume', this.volume);
    const engineName = this.readString(call, 'engine', '');
    const person = this.parsePerson(engineName);
    this.ensureEngine(person).then(() => {
      result.success(MAX_UTTERANCE_LENGTH);
    }).catch((error: Object) => {
      result.error('ENGINE_INIT_FAILED', this.describeError(error), null);
    });
  }

  private handleSpeak(call: MethodCall, result: MethodResult): void {
    const text = this.readString(call, 'text', '');
    const dartId = this.readString(call, 'id', '');
    if (text.length === 0 || dartId.length === 0) {
      result.error('INVALID_ARGUMENT', 'Missing required argument: text or id', null);
      return;
    }
    if (text.length > MAX_TEXT_LENGTH) {
      result.error('INVALID_ARGUMENT', `Text is longer than ${MAX_TEXT_LENGTH} characters`, null);
      return;
    }
    const queue = this.readBool(call, 'queue', false);
    if (this.engine === null) {
      this.ensureEngine(DEFAULT_PERSON).then(() => {
        this.enqueue(text, dartId, queue);
        result.success(null);
      }).catch((error: Object) => {
        result.error('ENGINE_INIT_FAILED', this.describeError(error), null);
      });
      return;
    }
    this.enqueue(text, dartId, queue);
    result.success(null);
  }

  // ---- playback ------------------------------------------------------------

  private enqueue(text: string, dartId: string, queue: boolean): void {
    if (!queue) {
      // A non-queued utterance preempts whatever is playing and drops the rest
      // of the queue: the caller asked to read this now.
      this.queue = [];
      this.dropCurrent();
    }
    const utterance = new Utterance();
    utterance.dartId = dartId;
    utterance.text = text;
    this.nextRequestSerial = this.nextRequestSerial + 1;
    utterance.requestId = `fqohos${this.nextRequestSerial}`;
    this.queue.push(utterance);
    if (this.current === null) {
      this.speakNext();
    }
  }

  private speakNext(): void {
    const engine = this.engine;
    if (engine === null || this.current !== null || this.queue.length === 0) {
      return;
    }
    const next = this.queue.shift();
    if (next === undefined) {
      return;
    }
    this.current = next;
    hilog.info(DOMAIN, TAG, 'speak requestId=%{public}s id=%{public}s chars=%{public}d',
      next.requestId, next.dartId, next.text.length);
    try {
      const params: textToSpeech.SpeakParams = { requestId: next.requestId };
      const extra: Record<string, Object> = {};
      // Both keys are documented for online engines; the offline engine may
      // ignore them, and that is fine - the SDK stays the source of truth.
      extra['isBackStage'] = true;
      params.extraParams = extra;
      engine.speak(next.text, params);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'speak failed: %{public}s', this.describeError(error));
      this.emitError(next.dartId);
      this.current = null;
      this.speakNext();
    }
  }

  private dropCurrent(): void {
    const engine = this.engine;
    const current = this.current;
    if (current === null) {
      return;
    }
    this.current = null;
    if (engine !== null) {
      try {
        engine.stop();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'stop failed: %{public}s', this.describeError(error));
      }
    }
  }

  private stopPlayback(): void {
    this.queue = [];
    const engine = this.engine;
    const current = this.current;
    this.current = null;
    if (engine !== null && current !== null) {
      try {
        engine.stop();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'stop failed: %{public}s', this.describeError(error));
      }
    }
  }

  // ---- listener callbacks --------------------------------------------------

  handleStart(requestId: string): void {
    const current = this.current;
    if (current === null || current.requestId !== requestId) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'start requestId=%{public}s id=%{public}s',
      requestId, current.dartId);
    const event: Map<string, Object> = new Map();
    event.set('type', 'start');
    event.set('id', current.dartId);
    // The Dart side maps this onto the sentence offset; a per-character offset
    // is not available from the engine, so start at the sentence beginning.
    event.set('start', 0);
    this.sendEvent(event);
  }

  handleComplete(requestId: string, type: number): void {
    const current = this.current;
    if (current === null || current.requestId !== requestId) {
      hilog.debug(DOMAIN, TAG, 'complete for stale requestId=%{public}s type=%{public}d',
        requestId, type);
      return;
    }
    if (type !== 1) {
      // type 0 means synthesis finished, playback keeps going until type 1.
      hilog.debug(DOMAIN, TAG, 'synthesis done requestId=%{public}s id=%{public}s',
        requestId, current.dartId);
      return;
    }
    this.current = null;
    const event: Map<string, Object> = new Map();
    event.set('type', 'done');
    event.set('id', current.dartId);
    this.sendEvent(event);
    this.speakNext();
  }

  handleError(requestId: string, errorCode: number, errorMessage: string): void {
    const current = this.current;
    hilog.error(DOMAIN, TAG, 'engine error requestId=%{public}s code=%{public}d message=%{public}s',
      requestId, errorCode, errorMessage);
    if (current === null || current.requestId !== requestId) {
      return;
    }
    this.current = null;
    this.emitError(current.dartId);
    this.speakNext();
  }

  private emitError(dartId: string): void {
    const event: Map<string, Object> = new Map();
    event.set('type', 'error');
    event.set('id', dartId);
    this.sendEvent(event);
  }

  private sendEvent(event: Map<string, Object>): void {
    const sink = this.events;
    if (sink === null) {
      return;
    }
    sink.success(event);
  }

  // ---- engine lifecycle ----------------------------------------------------

  private parsePerson(engineName: string): number {
    if (engineName.startsWith(ENGINE_PREFIX)) {
      const raw = engineName.substring(ENGINE_PREFIX.length);
      const person = Number.parseInt(raw, 10);
      if (!Number.isNaN(person) && person >= 0) {
        return person;
      }
    }
    return DEFAULT_PERSON;
  }

  private ensureEngine(person: number): Promise<void> {
    const existing = this.engine;
    if (existing !== null && this.person === person) {
      return Promise.resolve();
    }
    if (existing !== null) {
      this.releaseEngine();
    }
    return this.createEngine(person);
  }

  private async createEngine(person: number): Promise<void> {
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: person,
      online: 1,
    };
    const extra: Record<string, Object> = {};
    extra['style'] = 'interaction-broadcast';
    extra['locate'] = 'CN';
    // Keep playing while the app is in the background (reading sessions).
    extra['isBackStage'] = true;
    params.extraParams = extra;
    const engine = await textToSpeech.createEngine(params);
    this.engine = engine;
    this.person = person;
    engine.setListener(new SpeechListener(this));
    hilog.info(DOMAIN, TAG, 'engine ready person=%{public}d', person);
  }

  private releaseEngine(): void {
    const engine = this.engine;
    this.engine = null;
    this.person = -1;
    this.current = null;
    this.queue = [];
    if (engine !== null) {
      try {
        engine.shutdown();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'shutdown failed: %{public}s', this.describeError(error));
      }
    }
  }

  // ---- plumbing ------------------------------------------------------------

  private readString(call: MethodCall, key: string, fallback: string): string {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const text = value as string;
    return typeof text === 'string' ? text : fallback;
  }

  private readBool(call: MethodCall, key: string, fallback: boolean): boolean {
    const value: Any = call.argument(key);
    if (value === undefined || value === null) {
      return fallback;
    }
    const flag = value as boolean;
    return typeof flag === 'boolean' ? flag : fallback;
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
