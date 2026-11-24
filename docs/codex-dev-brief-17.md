# 交接单 17：接入真实数据前的安全闸 + Amazon 字段扩容

日期：2026-11-24
上游：交接单 16（提交 `55def0c`）

## 这单要解决什么

「接真实选品数据源」目前只剩一条路能走：Amazon 美国站前台（`distribution/l2/skills/market-research/scripts/fetch_amazon.py`，2026-11-24 实测返回美元价 `$7.64`、BSR `#1,397 in Pet Supplies`、5 点描述）。

但在把真实数据喂进打分表之前，`score_products.py` 有一个会产出假绿结论的口子，必须先堵。堵完再扩字段。

## 已复现的缺陷（证据原文，不是我推断的）

`distribution/l2/workspace/scripts/score_products.py:28-32`：

```python
def num(row, key, default=0.0):
    try:
        return float(str(row.get(key, default)).strip() or default)
    except ValueError:
        return default
```

缺列一律当 0。我用「抓取现在能给的 3 列」在 `/tmp` 副本里跑了一遍（**未动仓库**）：

输入：

```
品类,商品名,预估售价,头部评论数
家居,MateeyLife 慢食碗,7.64,10819
家居,Outward Hound 慢食碗,6.39,135893
```

输出：

```
排名 | 商品名 | 贡献利润 | 贡献率 | 分层 | 总分 | 决策
1 | MateeyLife 慢食碗 | 6.11 | 80.0% | 利润款 | 67.8 | 上架测试
2 | Outward Hound  | 5.11 | 80.0% | 利润款 | 42.3 | 放弃
```

`1688进价` 缺失被当成 0 → 表面毛利 100%、贡献利润率 80%、总分 67.8 → **直接判「上架测试」**。

同时 `在售竞品数`、`头部评论数` 缺失被当 0，`math.log1p(0)=0` 让 `d_comp`/`d_head` 归零，**竞争压力维度反向变轻，把分数推高**。三个维度里两个方向都错，系统性偏向「上架测试」。

**缺成本算出来的利润是虚的，这种结论不能出现在报告里。**

## T1 缺失值不等于 0（最高优先）

改 `score_products.py`，口径如下：

1. 区分「列不存在 / 值为空 / 非数字」与「真的是 0」。`num()` 不接受静默默认值。
2. 下列字段缺失时**该行必须不能给出正向决策**（`上架测试` / `小批量观察` 都不许出），并在输出的 `诊断` 列写明缺哪一列：
   - `1688进价`、`运费`、`平均退货率` —— 成本类，缺一个利润就是虚的
   - `月搜索量`、`在售竞品数`、`头部评论数` —— 需求/竞争类，缺了分数方向会错
3. 缺失行在输出里标 `[D]`（与 `toolchain-dispatch` 的证据等级口径一致），`决策` 列写 `补数据`，`总分` 留空或标 `NA`——**不要拿缺数据的行去算 minmax 归一化**，否则会污染其他行的分数。
4. `预估售价` 缺失仍按现有行为 `sys.exit`（它是唯一的硬门槛，现有实现已经这么做，别改坏）。
5. `推广费率`、`供应稳定性分` 是**有明确默认口径**的可选列，可以保留默认（0.15 / 5），但要在输出表头或诊断里注明用了默认值。

**负例必须自己跑并贴原文进交接单收尾**：用上面那份只有 3 列的 CSV 跑，断言**不再出现「上架测试」**、且诊断里点名缺失列。

现有的 `data/candidates.sample.csv` 九列齐全，修完它必须仍然跑出原来的结论（`上架测试` 两档都要在），别把正常路径改坏。

## T2 `fetch_amazon.py` 商品页扩三个字段

这三个字段已实测存在于商品页 HTML（`https://www.amazon.com/dp/B0C5HSCS8J`，2,238,048 字节，HTTP 200）：

| 字段 | 页面原文 | 取值方式 |
|---|---|---|
| `date_first_available` | `Date First Available : July 13, 2023` | 商品详情表里的 `<li>`，标签 `Date First Available` |
| `sold_by` | `Sold by MateeyLife` | `offer-display-feature-text` 区块，标签 `Sold by` |
| `ships_from` | `Ships from Amazon` | 同上，标签 `Ships from` |

新增派生字段 `fulfillment`：`ships_from` 含 `Amazon` → `fba`；含具体商家名 → `fbm`；取不到 → `unknown`。

**取不到一律 `null`，不许猜、不许填默认值。** `degraded` 里写明缺哪个字段。

**已确认拿不到的，不要浪费时间**：评分星级直方图（登录墙，HTML 里只有 `reviewCountTextLinkedHistogram` 这个类名，没有分布数据）、`Customers say` AI 摘要、评论原文（`/product-reviews/` 一律 302 到 `/ap/signin`）。这三样在做不到时按缺口记录，**不许用别的字段凑**。

## T3 批量模式：把真实抓取接成打分表的输入

给 `fetch_amazon.py` 加 `--asin-file <path>`（每行一个 ASIN，或带表头的 CSV 取 `asin` 列）：

1. 逐个抓商品页，串行，每次间隔 2–4 秒随机（沿用现有重试与退避口径，不要加快）。
2. 输出 CSV，列名**逐字对齐** `score_products.py` 读取的键：

```
asin,品类,商品名,预估售价,头部评论数,月搜索量,在售竞品数,1688进价,运费,平均退货率,推广费率,供应稳定性分,上架时间,卖家,发货方式,bsr,评分,抓取时间
```

3. 抓不到的列写 `NEED_INPUT`（不是空、不是 0），让 T1 的闸门能识别。
4. 文件头不加注释行（会破坏 `csv.DictReader`），缺失列说明写到同目录的 `<output>.README.md` 里。

## T4 文档与回归

1. `distribution/l2/skills/market-research/references/free-stack-verified.md` 补一节「商品页三个新字段的实测记录」，写明抓取时间、页面字节数、取到的原文值。
2. `distribution/l2/workspace/data/candidates.sample.csv` 不动（它是九列齐全的正常样例）。
3. `distribution/verify.sh` 或 `flow-smoke.sh` 增加一条断言：**只有 3 列的 CSV 跑打分，输出里不许出现「上架测试」**。这条是 T1 的回归锁。

## 验收（你自己跑，贴原文）

```bash
# 1. 正常路径没被改坏（九列样例仍出结论）
bash distribution/verify.sh
bash distribution/flow-smoke.sh

# 2. 负例：缺列不许出正向决策
#    （用 T1 里那份 3 列 CSV，贴完整输出）

# 3. 真实抓取新字段
python3 distribution/l2/skills/market-research/scripts/fetch_amazon.py product B0C5HSCS8J
#    断言输出里有 date_first_available / sold_by / ships_from / fulfillment 四项
```

## 边界

- 不碰 `farm/`、台账、`~/.dsh`、DS Bot 自身、系统设置。
- 不写真实凭证，不加任何需要花钱的依赖，python 只用标准库、兼容 3.9.6。
- **不许编数字**：取不到就是 `null` / `NEED_INPUT`，不许填估算值当成实测。
- 抓取要礼貌：单次间隔不低于 2 秒，一次不超过 20 个 ASIN。
- 完成后工作区要干净，改动只在本单范围内。
