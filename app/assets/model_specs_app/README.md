# model_specs_app（产物，供 desk 消费）

本目录是**生成器产物**：由工作区的本地库 `../model_specs/` 导出，供 desk（App）消费。

- **不要在此手改**；重新导出会覆盖。
- 生成器**只写本目录**，**绝不直接覆盖 desk 侧的 `model_specs_app`**（由 desk 自行从本产物同步）。
- 具体格式（是否带 `manifest.json`、字段适配）在 App 改造阶段确定。

规则见 [../SPEC.md](../SPEC.md)。
