# 已知问题

本页记录当前版本中已确认、但尚未修复的问题。

## 缩放窗口可能崩溃（Windows）

- **现象**：当**某些辅助工具正在访问本应用窗口**时，拖动窗口边缘缩放可能导致应用崩溃。该情况较少出现，没有此类工具访问时不会触发。
- **原因**：这是 Flutter（Windows）引擎的已知问题。我们已上报 Flutter 官方（[flutter/flutter#193410](https://github.com/flutter/flutter/issues/193410)），并为同一根因的既有 issue（[flutter/flutter#175041](https://github.com/flutter/flutter/issues/175041)）补充了确定性复现；上游已有对应修复在推进中，后续我们将跟随上游修复来消除此问题。
- **规避**：辅助工具访问窗口时不要缩放（稍后调整或先暂停该工具）；崩溃后重启可恢复，但条件仍在时会复现。
