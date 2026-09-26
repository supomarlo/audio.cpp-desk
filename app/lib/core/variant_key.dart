/// 变体键：把同一模型的不同精度 / 打包形态归一到同一「文档可描述的变体」。
///
/// 只归并「精度」与「打包形态」，保留尺寸、语言、变体名等有意义的维度。
/// 用于把音色/参考规则精确匹配到具体变体（例如 qwen3_tts 的 base / customvoice / voicedesign）。
class VariantKey {
  VariantKey._();

  static final _precision = RegExp(
      r'_(q8_0_v2|q4_k_int8_dit|f16_mixed|int8_dit|q8dit|q8_0|q4_0|q4_k_m|q4_k|q5_k_m|q5_k|q5_0|q6_k|q8_k|bf16|fp16|f16|f32|int8|orig|safetensors)(?=_|$)');
  static final _format = RegExp(r'_(?:gguf|local|mixed)(?=_|$)');

  static String of(String packageId) {
    var s = packageId.replaceAll(_precision, '');
    s = s.replaceAll(_format, '');
    return s;
  }
}
