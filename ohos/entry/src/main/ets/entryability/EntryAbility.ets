import { FlutterAbility, FlutterEngine, PluginRegistry } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { SecureKeysPlugin } from '../plugins/SecureKeysPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // App-owned plugins first: these back channels the Dart side already
    // speaks on Android (fqapp/secure_keys, fqapp/native_player, ...).
    const plugins: PluginRegistry | null = flutterEngine.getPlugins()
    if (plugins !== null) {
      plugins.add(new SecureKeysPlugin())
    }
    GeneratedPluginRegistrant.registerWith(flutterEngine)
  }
}