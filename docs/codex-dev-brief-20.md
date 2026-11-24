# brief-20：抓取节奏 / 限流诊断 / 缺列估算

## 背景（都是实测，不是推测）

1. **Amazon 前台现在被打到 503。** 我自己直连复现：
   ```
   $ python3 distribution/l2/skills/market-research/scripts/fetch_amazon.py search "pet slow feeder" --limit 3
   {"error": "http_503", "degraded": true, "rows": []}
   ```
   同一句话在 22:08 那次是通的（`搜索结果总数 5000（原文：5,000）`、10 个样本、`$6.39 / $7.4625 / $7.81 / $12.8 / $39.99`、rating 4.6、reviews 6–135893）。

2. **brief-19 首轮在线采集，10 个 Amazon 商品页 10 个全挂**：4 个 `http_503`、4 个 `blocked_by_amazon`。原因是 `screen_keyword.py` 的 `collect()` 只对相邻请求 `time.sleep(2)`，10 个商品页 ≈ 20 秒打完，把自己打死了。结果「进入难度」4 项（上架月龄 / 新品占比 / FBA 占比 / 卖家数）在实际使用中永远是 NA。

3. **在线模式不落原始抓取**，跑完只剩 md/csv，事后无法离线复现，`fixtures/screen/amazon_search.json` 里存的恰好是一次 503 的快照（`{"error": "http_503", ...}`），`amazon_products.json` 是 `[]`。所以 verify 的 7d 四条断言只覆盖了结构和负例，**「有数据时数值算得对」这条从未被任何断言覆盖**。

4. **打分表还缺 5 列**：`1688进价`、`运费`、`平均退货率`、`月搜索量`、`在售竞品数`。`score_products.py` 的安全闸现在会让它们全部落到「补数据」——这是对的，但产品经理拿不到任何可用估算。

## 任务

### T1 在线采集落盘原始 JSON

**文件**：`distribution/l2/skills/market-research/scripts/screen_keyword.py`

- 在线模式（不带 `--from-json`）在 `<out>/raw/` 下写三份原始抓取：
  `amazon_search.json`、`amazon_products.json`、`aliexpress_search.json`。
  内容就是把 `collect()` 拿到的 dict 原样 `json.dump`，字段必须和 `--from-json` 读的格式兼容。
- `--from-json <out>/raw` 必须能重放出同一份报告。

**验收**：
```bash
python3 .../screen_keyword.py "pet slow feeder" --top 3 --out /tmp/t1-online
python3 .../screen_keyword.py "pet slow feeder" --top 3 --from-json /tmp/t1-online/raw --out /tmp/t1-replay
diff "/tmp/t1-online/pet slow feeder-粗筛.csv" "/tmp/t1-replay/pet slow feeder-粗筛.csv"   # 必须无差异
```
Amazon 那轮即使 503 也算跑通（落盘的是 503 原文），重放结果必须照样一致。

### T2 限流诊断 + 退避

**新文件**：`docs/amazon-throttle.md`（诊断记录，只写你实际跑到的数）
**改文件**：`fetch_amazon.py`、`screen_keyword.py`

1. **诊断**：连续探测 Amazon 搜索页，记录「请求时刻 + http 状态」，最长观察 15 分钟，得出「503 是短时冷却还是持续封锁」的结论。把每次探测的时间与原文写进 `docs/amazon-throttle.md`。如果 15 分钟内一直 503，就如实写「15 分钟内未恢复」，不许编一个冷却时间。
2. **`fetch_amazon.py` 加退避**：
   - 识别 `429` / `503`，按 1s / 2s / 4s 指数退避重试，默认最多 3 次；
   - 新增 `--min-interval`（两次请求的最小间隔，默认 0 保持向后兼容）与 `--retries`（默认 3）；
   - 重试用尽仍是 503 → **照样返回 `{"error": "http_503", ...}`**，不许吞掉、不许当 0。
3. **`screen_keyword.py` 商品页节奏**：
   - 新增 `--product-interval`（默认 5 秒），`--product-limit`（默认与 `--top` 同）；
   - **连续 2 个商品页 503 就停止抓剩余商品页**，在报告「数据可信度」里写明「提前停止：剩余 N 个商品页未抓，原因 503」；
   - 停下后不许把未抓的商品页算进「unknown 分母」以外的任何统计（即分母只算实际抓过的）。

**红线**：
- 不加代理、不加 cookie、不换 IP、不改 UA 去绕。测出来是封锁就如实报封锁。
- 不许把 503 / 空结果当 0。
- 不许 `sleep` 死等到超过 15 分钟。

**验收**：
```bash
# 两次搜索之间确实隔开
python3 .../fetch_amazon.py search "pet slow feeder" --limit 2 --min-interval 5 --csv
# 连续 503 时提前停止
python3 .../screen_keyword.py "pet slow feeder" --top 10 --product-interval 5 --out /tmp/t2
grep "提前停止" "/tmp/t2/pet slow feeder-粗筛.md"
```
若当轮 Amazon 是通的，`提前停止` 那条自然不出现，改用离线 fixture 构造连续 503 验证（在 `fixtures/` 下加一份 `amazon_products_503.json`），**必须让这条逻辑被断言覆盖**。

### T3 缺列估算（brief-20 原定内容）

**新文件**：`distribution/l2/skills/market-research/scripts/estimate_columns.py`

输入粗筛 CSV（`screen_keyword.py` 的产物）或 `--from-json`，输出一张估算表，列：

`指标, 估算值, 公式, 证据等级, 不确定性, 备注`

至少覆盖这 5 列，能算的算、不能算的写 `NA` + 原因：

| 打分列 | 做法 | 证据等级上限 |
|---|---|---|
| `在售竞品数` | 由 `搜索结果总数` 映射（搜索命中数 ≠ 在售竞品数，必须写明这个偏差方向） | C |
| `1688进价` | 只能由 AliExpress 美元货源价当**上界**参考，不许当进价 | C |
| `月搜索量` | 无源 → `NA` | — |
| `平均退货率` | 无源 → `NA` | — |
| `运费` | 无源 → `NA` | — |

**红线（最关键的一条）**：
- 估算列**一律带 `估算_` 前缀**（`估算_在售竞品数` 等），不许直接产出 `在售竞品数`。
- 把估算结果喂给 `score_products.py`，**必须仍然输出「补数据」**，不许因为有了估算就变成「上架测试」。这是 safe-gate 的底线。
- 每条估算必须有公式 + 输入指标 + 证据等级 + 一句话不确定性，缺任何一项不许输出该行。
- 不许填 0。

**验收**：
```bash
python3 .../estimate_columns.py --from-json "/tmp/screen-online" --out /tmp/est.csv
# 输出里每一行都有非空公式与证据等级
python3 .../estimate_columns.py --from-json "/tmp/screen-online" --out /tmp/est.csv --as-score-input /tmp/score-in.csv
python3 distribution/l2/workspace/scripts/score_products.py /tmp/score-in.csv
# 必须仍然出现「补数据」，不许出现「上架测试」
```

### T4 补一套「有数据」的真实 fixture

**文件**：`distribution/l2/skills/market-research/scripts/fixtures/screen/`

- 如果 T2 跑完 Amazon 恢复：真抓 10 条搜索页存成 `amazon_search_ok.json`，商品页存 `amazon_products_ok.json`（**真实抓取，不许手写**）。
- `verify.sh` 加一条断言：用这套 ok 样本跑粗筛，「需求侧」6 项必须是证据等级 `B` 且值不为 `NA`。
- **如果 15 分钟内 Amazon 一直不通**：不造假 fixture，在 `docs/amazon-throttle.md` 与交接单「收尾」写明「本轮未能取到可用样本」，并在 verify 里把这条断言写成「有 ok 样本才跑，没有则记 WARN 并打印原因」。

### T5 verify 扩充

`distribution/verify.sh` 加一节 `7e. 粗筛离线重放与估算闸门`，至少四条：
1. T1 的重放一致性（同一份 raw 重放，CSV 逐字相同）；
2. 连续 503 提前停止（用 fixture 构造）；
3. 估算表每行都有公式与证据等级；
4. **估算列喂进 `score_products.py` 仍然输出「补数据」**。

## 范围与红线

- **只许改**：`screen_keyword.py`、`fetch_amazon.py`、新建 `estimate_columns.py`、`distribution/verify.sh`、`fixtures/screen/` 下的新文件、`docs/amazon-throttle.md`、本交接单的「收尾」节。
- **不许改**：`fetch_aliexpress.py`、`score_products.py`、`distribution/flow-smoke.sh`、其他 skill、`farm/`、任何台账。
- 改完 `distribution/l2/skills/...` 必须同步到 `distribution/l2/bundle/skills/...`，`diff -qr` 必须零差异。
- python 只用标准库、兼容 3.9.6；不加依赖；不写真实凭证。
- **不要 commit、不要 push**，改完停在 utf-8 干净工作区等我验收。
- 不许伪造任何抓取数据；所有写进文档的数字必须是你自己跑出来的。

## 收尾

改完把下面内容追加到本文件末尾（原文贴出，不要转述）：

1. `bash distribution/verify.sh` 的完整汇总行与新增断言的原文；
2. `bash distribution/flow-smoke.sh` 的汇总行；
3. `docs/amazon-throttle.md` 里的诊断结论；
4. 一次在线粗筛的完整 CSV（哪怕是全 NA 也要贴）；
5. `diff -qr distribution/l2/skills distribution/l2/bundle/skills` 的输出（应为空）。
