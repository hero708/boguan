import common from '@ohos.app.ability.common';

// FlutterPluginBinding only exposes the application context, but continuous
// tasks and AVSession need the UIAbility context (401 invalid context
// otherwise). EntryAbility installs the real one during onCreate.
export class AbilityContextHolder {
  static context: common.UIAbilityContext | null = null;
}
