# model_specs_app（生成器产物 / desk overlay）

本目录是生成器的**增强 overlay 产物**，由生成器根据 `../model_specs/`（上次生成基线）与 `../model_specs_audio.cpp/`（最新上游）生成，供 desk 消费。

- 只包含 `family`、`i18n`、`packages[].id/i18n/sizes/downloads/task`；
- 不含运行时字段；desk 运行时以服务端 / 所选版本的 `model_specs` 为准；
- 默认由生成器维护；用户手改并**主动通知**的翻译 / 文案视为**权威**，生成 / 合并时必须保留，不得自动覆盖；
- 未通知的差异先询问用户，不得自动覆盖或擅自视为权威；
- 生成器只写本目录，**绝不直接覆盖 desk 侧的 `model_specs_app`**（由 desk 自行同步）。

规则见 [../SPEC.md](../SPEC.md)。
