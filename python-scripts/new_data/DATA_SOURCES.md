# new_data/ — 2000–2024 选举数据来源说明

由 `build_year_state_dbs.py` 生成（2024 由 `build_2024_state_dbs.py` 生成）。
每个年份一个目录：`<year>/<CODE>-<year>.db`（每州一个）、`National-<year>.db`、
`manifest.json`（含 size / sha256 / 各州竞选列表）和 `BUILD_REPORT.md`（逐州逐竞选的票数与备注）。
`new_elections.json` 按年份列出各州 db 的 CDN 地址。

所有 db 与 2024 同一 schema（schema 2）：几何表（counties / congressional_districts / precincts /
county_precincts / congressional_district_precincts / state_regions）+ elections / parties / candidates /
precinct_results / meta。`meta.level` 说明该 db 的最小单元是 `precinct` 还是 `county`。

## 各年份数据层级与来源

| 年份 | 层级 | 竞选 | 来源 | 覆盖 |
|---|---|---|---|---|
| 2000 | county | President, US Senate, Governor | Algara & Amlani 县级数据集（DGUMFI） | 50 州（无 AK，见下） |
| 2001 | county | Governor | 同上 | NJ, VA |
| 2002 | county | US Senate, Governor | 同上 | 有相应竞选的州 |
| 2003 | county | Governor | 同上 | KY, LA, MS |
| 2004 | county | President, US Senate, Governor | 同上 | 50 州 |
| 2005 | county | Governor | 同上 | NJ, VA |
| 2006 | county | US Senate, Governor | 同上 | 有相应竞选的州 |
| 2007 | county | Governor | 同上 | KY, LA, MS |
| 2008 | county | President, US Senate, Governor | 同上 | 50 州 |
| 2009 | county | Governor | 同上 | NJ, VA |
| 2010 | county | US Senate, Governor | 同上 | 有相应竞选的州 |
| 2011 | county | Governor | 同上 | KY, LA, MS |
| 2012 | precinct (FL, KS) / county (其余) | President, US Senate, Governor | VEST 2012（FL、KS）；其余 DGUMFI | 50 州 |
| 2013 | county | Governor, US Senate (special) | DGUMFI | MA, NJ, VA |
| 2014 | county | US Senate, Governor | DGUMFI | 有相应竞选的州 |
| 2015 | county | Governor | DGUMFI | KY, LA, MS |
| 2016 | precinct | President, US Senate, US House, Governor | VEST 2016 + MEDSL 2016 众议院精选区数据 | 50 州 + DC |
| 2017 | precinct | US Senate (special), Governor | VEST 2017 | AL, NJ, VA |
| 2018 | precinct（CA、KY 为 county × 国会选区） | US Senate, US House, Governor | VEST 2018 + MEDSL 2018；CA、KY 用 MEDSL 2018 按县 × 选区汇总 | 50 州 + DC |
| 2019 | county | Governor | DGUMFI | KY, LA, MS |
| 2020 | precinct | President, US Senate, US House*, Governor | VEST 2020（几何复用 data/2020-output） | 50 州 + DC |
| 2021 | precinct | Governor | VEST 2021 | NJ, VA |
| 2022 | county × 国会选区 | US Senate, US House, Governor | MEDSL 2022 精选区数据按县 × 选区汇总 | 50 州 |
| 2023 | county | Governor | OpenElections（KY, MS）、路易斯安那州务卿网站（LA） | KY, LA, MS |
| 2024 | precinct | 全部 | 见 2024/BUILD_REPORT.md | 50 州 |

### 来源链接

- VEST（Voting and Election Science Team）精选区 shapefile，Harvard Dataverse：
  2012 `doi:10.7910/DVN/B3NTZR`、2016 `NH5S2I`、2017 `VNJAB1`、2018 `UBKYRU`、2020 `K7760H`、2021 `FDMI5F`。
  候选人姓名与政党取自各数据集的 `documentation.txt`。原始文件在 `data/<year>-raw-data/`。
- Algara & Amlani, *Partisanship & Nationalization in American Elections* 复现数据（`doi:10.7910/DVN/DGUMFI`）：
  1868–2020 县级总统 / 参议员 / 州长回报，只有民主党与共和党提名人的票数和县总票数，
  其余候选人合并为 "Other"。原始文件在 `data/county-raw-data/`。
- MEDSL（MIT Election Data and Science Lab）：
  2016 众议院精选区数据（`doi:10.7910/DVN/PSKDUJ`）、2018 各州精选区数据（GitHub `MEDSL/2018-elections-official`）、
  2022 各州精选区数据（GitHub `MEDSL/2022-elections-official`）。
- OpenElections：`openelections-data-ky` 2023 各县精选区 CSV、`openelections-data-ms` 2023 县级 CSV。
- 路易斯安那州务卿选举结果站 `voterportal.sos.la.gov`（2023-10-14 开放初选，Landry 首轮当选）。
- Census 制图边界文件（`data/census/`）：县界按年份取最接近的版本
  （2000–2001 用 2000 版 co99_d00，2002–2013 用 2010 版，之后用 cb_2014 / 2016 / 2018 / 2020 / 2021），
  国会选区 cb_2016 CD115、cb_2018 CD116、cb_2020 CD116、cb_2022 CD118；2022 阿拉斯加用 cb_2022 州众议院选区。

## 需要知晓的推定与缺口

1. **县级年份（2000–2015、2019、2023）**：每个县同时作为一个 precinct，`precincts` 与 `counties` 一一对应；
   没有国会选区层（`congressional_districts` 为空），也没有众议院竞选——网上没有 2016 年以前的公开精选区 / 县级众议院数据。
2. **阿拉斯加在县级年份缺席**：Algara & Amlani 数据集不含阿拉斯加（该州按选区而非行政区报票）。
3. **DGUMFI 只区分 D / R / Other**：第三党候选人一律并入 "Other"；总统 2000–2012 亦然（2016 起为 VEST 逐候选人）。
4. **2016 / 2018 众议院**：VEST 图层本身只含少数州的众议院列；其余州来自 MEDSL 精选区数据。
   精选区名称能与 VEST 图层匹配（≥90% 票数）的州按精选区写入；匹配不上的州把 MEDSL 的县 × 选区总票
   按各精选区在州级竞选中的票数比例分摊到该县属于该选区的精选区上（选区总票精确，精选区分布为估计）。
   每州采用了哪种方式写在 BUILD_REPORT.md 的 note 里。
5. **2020 众议院只有单选区州**（AK, DE, MT, ND, SD, VT, WY, DC）：VEST 2020 图层没有众议院列，
   MEDSL 2020 众议院精选区数据（`doi:10.7910/DVN/VLGF2M`）需要在 Dataverse 填写 guestbook 后才能下载。
   下载后把 `HOUSE_precinct_general.csv` 放到 `data/2020-raw-data/medsl/`，重跑
   `build_year_state_dbs.py --years 2020` 即可按 2018 的同一流程补上。
6. **2022**：MEDSL 2022 只有精选区表格没有边界，因此单元是"县 × 国会选区"多边形
   （Census 县界与 CD118 相交），众议院票数按县 × 选区精确落位；参议员 / 州长按精选区所属选区归入相应块。
   阿拉斯加以 40 个州众议院选区代替县；密苏里州堪萨斯城（独立选举委员会）计入 Jackson County。
7. **2018 CA / KY**：VEST 2018 没有这两州的图层，改用 MEDSL 2018 精选区表格按"县 × 国会选区"汇总（同 2022 的做法）。
8. **2023 LA**：路易斯安那 2023 州长为 10 月 14 日开放初选一轮定胜负，写入的是该轮各教区票数。
9. **2020 几何**：直接复用 `data/2020-output/2020-National-President/<CODE>.db`（含 DC），
   选举表按 2024 的方式重建；总统候选人改用 VEST 文档中的全名。
10. 精选区→县、精选区→国会选区的归属在无字段可用时按几何（内点落入多边形）推定，同 2020/2024 导入器。
11. **DC**：只保留总统与众议院代表（delegate）；VEST 标为 USS 的"影子参议员"不写入 US Senate。
12. **National-<year>.db 的 `states.vote_summary`**：取该州当年的总统竞选，没有则依次取州长、参议员；只有众议院竞选的州（如 2018、2022 的部分州）取众议院全部候选人汇总。`state_elections` 表列出每州每场竞选的候选人汇总。
13. **VEST 文档缺失的列**（如 NE 2020 参议员 Gene Siadek、OH 2020 总统 Howie Hawkins）在脚本 `NAME_OVERRIDES` 中手工补齐。

## 重建

```bash
cd python-scripts
.venv/bin/python build_year_state_dbs.py --years 2016          # 一个或多个年份
.venv/bin/python build_year_state_dbs.py --years 2022 --states MO
.venv/bin/python build_year_state_dbs.py --years 2000 2004 --manifest-only   # 只重写 manifest / National / new_elections.json
```
