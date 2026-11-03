import 'package:flutter/widgets.dart';

import '../../models/model_spec.dart';
import '../../models/session.dart';
import 'workbench_contract.dart';

/// 专属 Widget 构建参数。
class WorkbenchWidgetContext {
  const WorkbenchWidgetContext({
    required this.spec,
    required this.dict,
    required this.submit,
    this.selectedRecord,
    this.availableHeight,
  });

  final ModelSpec spec;
  final Map<String, String> dict;

  /// 当前选中的记录，供模型 Widget 展示自己的结果。
  final GenerationRecord? selectedRecord;

  /// 工作台动态区可用高度，供模型结果区自适应。
  final double? availableHeight;

  /// Widget 的提交入口；外壳负责校验提示、入队与记录。
  final void Function(WorkbenchModelController controller) submit;
}

/// 专属模型控制器：表单状态、提交方案、记录恢复。
abstract class WorkbenchModelController extends ChangeNotifier {
  /// 返回缺失字段的词条 key；null 表示可提交。
  String? validate();

  /// 高级参数保存回调；由工作台外壳设置。
  void Function()? onAdvancedSaved;

  /// 通知外壳持久化当前高级参数。
  void saveAdvancedValues() => onAdvancedSaved?.call();

  /// 产出完整提交方案；null 表示暂不可提交。
  WorkbenchCall? buildCall();

  void restore(GenerationRecord record);

  /// 可跨重启持久化的高级参数；模型控制器按需覆盖。
  Map<String, String> advancedValues() => const {};

  /// 首次创建控制器时回填持久化的高级参数。
  void setAdvancedValues(Map<String, String> values) {}
}

typedef WorkbenchControllerFactory = WorkbenchModelController Function(
  String packageId,
  ModelSpec spec,
);

typedef WorkbenchWidgetBuilder = Widget Function(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
);

class WorkbenchRegistration {
  const WorkbenchRegistration({
    required this.controller,
    required this.builder,
  });

  final WorkbenchControllerFactory controller;
  final WorkbenchWidgetBuilder builder;
}

/// 工作台动态区注册表：`family + task` → 专属 Widget。
class WorkbenchRegistry {
  static final Map<String, Map<String, WorkbenchRegistration>> _registrations =
      {};

  static void register(
    String family,
    String task, {
    required WorkbenchControllerFactory controller,
    required WorkbenchWidgetBuilder builder,
  }) {
    _registrations[family] ??= {};
    _registrations[family]![task] = WorkbenchRegistration(
      controller: controller,
      builder: builder,
    );
  }

  static WorkbenchRegistration? registrationFor(String family, String task) =>
      _registrations[family]?[task];

  static bool isAdapted(String family, String task) =>
      registrationFor(family, task) != null;

  static bool hasAnyAdapted(String family, List<String> tasks) {
    for (final task in workbenchTasksOf(tasks)) {
      if (isAdapted(family, task)) return true;
    }
    return false;
  }
}
