import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/strings.dart';
import '../../providers/app_providers.dart';

class LanguageSwitch extends ConsumerWidget {
  const LanguageSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    // 当前只有两种语言：点击直接切换到另一种；将来多语言再改回弹出菜单。
    final other =
        AppLocale.values.firstWhere((l) => l != locale, orElse: () => locale);
    return Padding(
      // 单独抬高语言图标（增加底部边距），不影响上方导航菜单。
      padding: const EdgeInsets.only(bottom: 8),
      child: IconButton(
        icon: const Icon(Icons.language),
        // 提示显示"另一种语言"的母语名（当前中文→English，当前英文→中文）。
        tooltip: other.nativeName,
        onPressed: () => ref
            .read(appConfigProvider.notifier)
            .update((c) => c.locale = other.code),
      ),
    );
  }
}
