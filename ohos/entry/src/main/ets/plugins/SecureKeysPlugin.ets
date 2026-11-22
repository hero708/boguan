import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import asset from '@ohos.security.asset';

const DOMAIN = 0xF0A0;
const TAG = 'fqapp_secure_keys';
const CHANNEL = 'fqapp/secure_keys';
const ERROR = 'KEYSTORE';
/** Asset Store error code for a missing / duplicated alias. */
const ASSET_NOT_FOUND = 24000002;
const ASSET_DUPLICATED = 24000003;

/**
 * BusinessError carries the interesting part in `code`; `message` is often
 * empty, which used to make the Dart-side log useless.
 */
function describeError(error: Object): string {
  const business = error as BusinessError;
  const code: number | undefined = business?.code;
  const message: string | undefined = business?.message;
  if (code !== undefined && (message === undefined || message.length === 0)) {
    return `Asset error ${code}`;
  }
  if (message !== undefined && message.length > 0) {
    return code !== undefined ? `${code}: ${message}` : message;
  }
  return JSON.stringify(error);
}

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

/**
 * 本机密钥库（HarmonyOS）。
 *
 * 与 Android `SecureKeyPlugin` 对应：信道、方法名与参数完全一致
 * （`read`/`write`/`delete` + `{key, value}`），Dart 侧无需区分平台。
 *
 * 后端是 **Asset Store Kit**（`@ohos.security.asset`）——系统提供的"小段秘密"
 * 存储，等价 iOS Keychain：密钥材料由系统安全服务管理，应用既不持有密钥也
 * 不做加解密。这里只把 Dart 传来的 Base64 值解码成字节存进去，读时再编码回来。
 *
 * 之所以不用 HUKS（Android 的 Keystore 对应物）：本机 API 26 上 HUKS 的对称
 * 会话只有加密方向可用（生成密钥后 encrypt 成功，decrypt 的 initSession 分别
 * 报 401 / 12000012），重启后解不开自己刚写入的条目，等于不可用。详见
 * `docs/` 的 M1 调试记录。
 *
 * 任何失败都回报错误给 Dart（fail closed），绝不回落明文存储。
 */
export class SecureKeysPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'fqapp.secure_keys';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    const name = call.argument('key') as string;
    if (name === undefined || name === null || name.length === 0) {
      result.error(ERROR, '缺少 key', null);
      return;
    }
    try {
      if (call.method === 'read') {
        result.success(await this.read(name));
        return;
      }
      if (call.method === 'write') {
        const value = call.argument('value') as string;
        if (value === undefined || value === null) {
          result.error(ERROR, '缺少 value', null);
          return;
        }
        await this.write(name, value);
        result.success(null);
        return;
      }
      if (call.method === 'delete') {
        await this.remove(name);
        result.success(null);
        return;
      }
      result.notImplemented();
    } catch (error) {
      const message = describeError(error);
      hilog.error(DOMAIN, TAG, 'secure key %{public}s failed: %{public}s', call.method, message);
      result.error(ERROR, message, null);
    }
  }

  private aliasOf(name: string): Uint8Array {
    return toBytes(name);
  }

  /** Reads the secret back as Base64; a missing entry answers null. */
  private async read(name: string): Promise<string | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.aliasOf(name));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let rows: Array<asset.AssetMap>;
    try {
      rows = await asset.query(query);
    } catch (error) {
      const code = (error as BusinessError)?.code;
      if (code === ASSET_NOT_FOUND) {
        return null;
      }
      throw new Error(describeError(error));
    }
    if (rows === undefined || rows === null || rows.length === 0) {
      return null;
    }
    const secret = rows[0].get(asset.Tag.SECRET) as Uint8Array;
    if (secret === undefined || secret === null || secret.length === 0) {
      return null;
    }
    return new util.Base64Helper().encodeToStringSync(secret);
  }

  private async write(name: string, value: string): Promise<void> {
    const secret = new util.Base64Helper().decodeSync(value);
    // Asset Store rejects a duplicated alias, so replace instead of failing on
    // the second write of the same key.
    await this.removeQuietly(name);
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, this.aliasOf(name));
    attributes.set(asset.Tag.SECRET, secret);
    // Readable as soon as the device has been unlocked once since boot: the app
    // must be able to boot straight from a cold start without an extra prompt.
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(attributes);
    hilog.info(DOMAIN, TAG, 'stored key=%{public}s bytes=%{public}d', name, secret.length);
  }

  private async remove(name: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.aliasOf(name));
    await asset.remove(query);
    hilog.info(DOMAIN, TAG, 'removed key=%{public}s', name);
  }

  private async removeQuietly(name: string): Promise<void> {
    try {
      await this.remove(name);
    } catch (error) {
      const code = (error as BusinessError)?.code;
      if (code === ASSET_NOT_FOUND || code === ASSET_DUPLICATED) {
        return;
      }
      throw new Error(describeError(error));
    }
  }
}