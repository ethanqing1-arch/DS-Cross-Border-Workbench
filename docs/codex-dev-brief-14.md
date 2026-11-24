# 交接单 14：修 `requires` 不被校验的洞

日期：2026-11-24
上游：交接单 13（提交 `3edfbc4`）

## 背景（派单人已核实，不是推测）

证据链完整，按顺序看：

1. 派单人做了变异测试：把 `distribution/l3/platforms/ebay/manifest.json:7` 的 `kualang-cbec` 改回 `dsh-ecom-cbec`，跑 `bash distribution/verify.sh`：

```text
变异后该文件里的旧 id：
7:    "dsh-ecom-cbec": ">=0.1.0",
=== verify 结果 ===
== 汇总: PASS=68 FAIL=0 WARN=0 ==
RESULT: READY
```

**改错了包名，verify 照样全绿。**

2. 原因在 `distribution/l3/install.sh:71-100`：那段名为「平台 manifest schema 校验」的代码是**手写的部分检查器**，只检查 `schema.required` 顶层字段、`mf.id` 与目录名、`tier` 枚举、`version` 格式、`skills.mode` 枚举、`overrides.path` 类型。**从未读取 `mf.requires`。**

3. `distribution/l3/schema/platform.schema.json:29-38` 给 `requires` 写了这些约束：

```json
"requires": {
  "type": "object",
  "additionalProperties": false,
  "required": ["kualang-cbec"],
  "properties": {
    "kualang-cbec": { "type": "string", ... },
    "browser-farm": { "type": "string", ... }
  }
}
```

这些约束**没有任何代码执行**，是装饰品。

4. `requires` 在运行时也没被消费：`l3/install.sh:183,189` 的「L2 双证」是硬编码字符串判断，不读 manifest 的 `requires`。

5. 后果：10 处 `requires` 改名（7 个平台 + `platform-template` + `l3/manifest.json` + `schema`）没有任何测试或运行时覆盖，写错完全静默。

## T1 让 `requires` 真的被校验（必做）

改 `distribution/l3/install.sh` 里那段校验，**从 schema 文件读约束而不是继续硬编码**：

- `requires` 必须是对象
- 必须包含 `schema.properties.requires.required` 列出的键
- 键集合必须**等于** `schema.properties.requires.properties` 的键集合（这才落实 `additionalProperties: false`）
- 每个值必须是非空字符串且形如 `>=x.y.z`
- 报错沿用现在的风格：`  FAIL <原因>` 若干行 + `FAIL 平台 manifest 未通过 schema 校验`，然后 `exit 1`

**不要引入任何 JSON Schema 库**，保持零依赖、只读文件不装包。

## T2 补负例进 verify.sh（必做，这是本单的验收核心）

`distribution/verify.sh` 加一条负例：把某个平台的 `requires` 键临时改成错误名字，断言 `l3/install.sh` 必须 FAIL 且 0 写入，然后把文件还原。

要求：

- 必须真的证明「错误键名会被抓住」，不是只证明「坏 JSON 会被抓住」
- 还原用副本覆盖，不要在仓库里留痕迹；脚本退出（含异常路径）也要还原，用 trap 兜
- 负例不能污染后续断言，跑完 `git status` 必须干净

## T3 顺带列事实（必做，只读）

确认 7 个平台 + `platform-template` 的 `requires` 当前都是 `kualang-cbec` + `browser-farm`，在回报里列成表，每行写文件路径和两个键的值。

## 明确不做的事

- **不做版本号判断。** `l3/README.md:82` 已记录「L2 的 install.sh 不把 manifest.json 落到目标目录，所以 requires 现在只能靠双证存在判，判不了版本号」。这单只修「键名与结构不被校验」，不扩成版本闸。不许顺手把 L2 的落点文件数改掉。
- 不动 `requires` 的语义、不加新字段、不加迁移代码、不加向后兼容。
- 不碰 `farm/`、不碰 `~/.dsh`。
- 不改 `docs/codex-dev-brief-*.md`（历史记录）。

## 验证（你自己跑，原样贴输出，不要改写）

```bash
# 1. 正常验收
bash distribution/verify.sh

# 2. 负例那一条的原文
#    （就是你在 verify.sh 里新加的那条，贴它自己的输出行）

# 3. 手工变异复现：改回旧 id，verify 现在必须 FAIL
cp distribution/l3/platforms/ebay/manifest.json /tmp/ebay.bak
sed -i '' 's/"kualang-cbec"/"dsh-ecom-cbec"/' distribution/l3/platforms/ebay/manifest.json
bash distribution/verify.sh; echo "exit=$?"
cp /tmp/ebay.bak distribution/l3/platforms/ebay/manifest.json
grep -n 'kualang-cbec' distribution/l3/platforms/ebay/manifest.json
```

硬性要求：

1. 第 1 条全 PASS，PASS 数按实跑报。
2. 第 3 条必须 **FAIL 且退出码非 0**，贴出 FAIL 原文。这是本单唯一能证明洞被堵上的证据。
3. 还原后 `git status --short` 只能有你自己改动的文件。
4. 回填 `README.md` 与 `docs/roadmap.md` 里的 PASS 数——**用你自己跑出来的数字**，不许照抄现有值。

## 交付

- 提交前 `git diff --check`。
- 提交信息说明修的是 `requires` 未被校验。
- **不要推远端。**
- 不要动 `docs/codex-dev-brief-14.md` 本身（未跟踪，派单人自己提交）。
