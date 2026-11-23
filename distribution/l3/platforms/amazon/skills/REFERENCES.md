# Amazon 专项 skill 引用声明（不随包分发）

本目录只放「引用声明」，**不含任何 SKILL.md 内容**。

## 声明

| 项 | 值 |
|---|---|
| 来源包 | `cbec-selection-master` |
| 层结构 | `00-router` `01-data` `02-market` `03-demand` `04-competitor` `05-product` `06-delivery` `07-system` |
| skill 总数 | 23（依据：`docs/dsh-ecom-productization-plan.md:132`「现有 8 层 23 个」） |
| 每层各几个 | **未统计**：源码不在本机，不猜 |
| 授权归属 | 待定（计划第 6 节第 3 条），确认前不得随产品分发 |

## 本机核对原文（2026-11-23）

```
$ find ~/.dsh ~/ds-bot-workspace ~/Projects/DS-Cross-Border-Workbench -maxdepth 4 -iname "*cbec*"
（无输出）
```

=> 本机没有 `cbec-selection-master` 副本。

## 要真装这 23 个 skill，还差什么

1. 把 `cbec-selection-master` 源码放到本机（现在没有）。
2. 按 `skills/<NN>-<layer>/<skill-name>/SKILL.md` 拷进本目录。
3. 把 `manifest.json` 的 `skills.mode` 从 `referenced` 改成 `bundled`，并补每层实际数量。
4. 确认授权归属（计划第 6 节），否则不分发。

## 为什么现在只声明

1. 内容不在本机，拷不了，也不凭印象造。
2. 授权归属未定，随包分发有法律风险。
3. 基线档的价值是先跑通「装一个平台」这个动作，skill 后补不影响这件事。
