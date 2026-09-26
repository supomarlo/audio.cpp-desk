class HealthInfo {
  HealthInfo({
    required this.status,
    required this.backend,
    required this.models,
    required this.ui,
    required this.uiManagement,
  });

  final String status;
  final String backend;
  final int models;
  final bool ui;
  final bool uiManagement;

  static HealthInfo fromJson(Map<String, dynamic> json) {
    return HealthInfo(
      status: json['status'] as String? ?? '',
      backend: json['backend'] as String? ?? '',
      models: (json['models'] as num?)?.toInt() ?? 0,
      ui: json['ui'] as bool? ?? false,
      uiManagement: json['ui_management'] as bool? ?? false,
    );
  }
}