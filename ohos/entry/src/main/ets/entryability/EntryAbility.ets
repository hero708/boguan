import { FlutterAbility, FlutterEngine, PluginRegistry } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { SecureKeysPlugin } from '../plugins/SecureKeysPlugin';
import FqPlayerPlugin from '../plugins/FqPlayerPlugin';
import SystemTtsPlugin from '../plugins/SystemTtsPlugin';
import { AbilityContextHolder } from '../plugins/AbilityContextHolder';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // Continuous tasks and AVSession reject the application context, so the
    // media plugin needs the real UIAbility context. FlutterPluginBinding only
    // exposes the application one; keep the ability's here.
    AbilityContextHolder.context = this.context
    // App-owned plugins first: these back channels the Dart side already
    // speaks on Android (fqapp/secure_keys, fqapp/native_player, ...).
    const plugins: PluginRegistry | null = flutterEngine.getPlugins()
    if (plugins !== null) {
      plugins.add(new SecureKeysPlugin())
      plugins.add(new FqPlayerPlugin())
      plugins.add(new SystemTtsPlugin())
    }
    GeneratedPluginRegistrant.registerWith(flutterEngine)
  }
}
