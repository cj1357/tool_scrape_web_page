# LP 页面抓取工具

这个项目读取脚本目录下 CSV 的 `LP URL` 字段，在 Windows VPS 上抓取落地页内容。它会自动识别当前 AdRadar CSV 使用的 **GB18030/GBK** 编码，也兼容 UTF-8 CSV。

每个去重后的 URL 会保存：

- `page.html`：只保留文章主体并清除广告/非正文区块后的 HTML
- `text.txt`：从清洗后文章主体提取的可读文本
- `images/`：只从文章主体的 HTML、`srcset`、常见 lazy-load 属性和内联 CSS 中找到的图片
- `images.csv` / `images.json`：每张图片的来源、状态、本地文件名和错误信息
- `result.json`：页面状态、最终跳转 URL、标题、来源 CSV 行号等

整个任务的汇总位于 `scraped_output/summary.csv` 和 `summary.json`。

## 清洗为落地页 / Search 页数据

抓取完成并把 `scraped_output/` 拉回项目后，在项目根目录执行：

```powershell
python -m pip install -r requirements-clean.txt
Set-ExecutionPolicy -Scope Process Bypass
./clean-articles.ps1
```

指定其他项目内输出目录时：

```powershell
./clean-articles.ps1 -OutputDirectory ./cleaned_data_test
```

清洗器会读取根目录下的 `adradar_*.csv` 和 `scraped_output/`，排除拒绝页、广告/搜索推荐、导航、Cookie、分享、页脚和品牌 Logo；按规范化正文精确去重，并把文章正文转为模板可直接消费的结构化块。每次运行会重新生成整个输出目录。

当前数据生成结果是：188 个抓取页，84 个拒绝页，104 个有效 URL，去重后 71 篇实际文章。

```text
cleaned_data/
├─ manifest.json                 # 数量汇总与公开字段清单
├─ articles.json                 # 全部文章数组
├─ articles.csv                  # 便于人工筛选和审阅的扁平表
├─ search-index.json             # Search 页使用的轻量索引
├─ articles/
│  └─ <slug>.json                # 每篇文章一个 JSON
├─ assets/articles/<slug>/
│  └─ hero.<ext>                 # 正文图片，不含站点 Logo
└─ reports/
   ├─ rejected.csv               # 无实际正文 / Access denied
   ├─ duplicates.csv             # URL 到去重文章的映射
   ├─ near-duplicates.csv        # 近似重复候选
   ├─ repaired-titles.csv        # 空、拒绝页或乱码 LP Title 修复记录
   └─ term-review.csv            # term 输入、结果和校验状态
```

单篇文章 JSON 字段如下：

- `id`、`slug`、`title`、`published_at`、`read_minutes`
- `language`、`locale`、`locations`
- `ad_contents`、`lp_titles`
- `term`：Search/List 广告可直接使用的空格连接字符串
- `term_items`：`term` 对应的 4–6 个独立关键词组
- `excerpt`
- `content_blocks`：顺序保存 `heading`、`paragraph`、`list`、`table`、`image`、`disclaimer`

单篇 JSON 特意不包含 `content_html`、`sources`、`content_hash`。来源、去重和修复信息只放在独立报告里。

清洗和 term 规则测试：

```powershell
python -m unittest -v test_clean_articles.py
```

## 在 Windows VPS 上运行

建议使用 PowerShell 7；Windows PowerShell 5.1 也可以运行。

```powershell
git pull
Set-ExecutionPolicy -Scope Process Bypass
./scrape-lp.ps1
```

脚本默认读取项目根目录下的所有 `*.csv`，输出到 `scraped_output/`。CSV 里的 `{placement}` 和 `{creative}` 广告宏会分别替换成稳定的 `vps_scraper` 和 `0`，避免直接请求时 URL 无效。

如果网页依赖 JavaScript 或图片是动态生成的，使用 Windows 自带的 Edge 无头渲染：

```powershell
./scrape-lp.ps1 -RenderWithEdge
```

Edge 每页默认等待 10 秒。较慢页面可以延长：

```powershell
./scrape-lp.ps1 -RenderWithEdge -EdgeRenderMilliseconds 20000
```

## 正文和广告过滤

脚本会优先定位 `<article>`、文章内容容器或 `<main>`，只保留下列内容：标题、日期、正文段落、各级标题、列表、表格和正文配图。默认过滤：

- `Research topics`、Related searches、Sponsored links 等搜索推荐/广告块
- Google Ads、DoubleClick、Taboola、Outbrain 等广告和追踪资源
- iframe、广告位、导航、Logo、分享按钮、订阅/搜索表单、Cookie 条和页脚
- tracking pixel、beacon、spacer 等追踪图片

默认不保存可能含广告代码的原始 HTML。只有排查网页结构时才临时使用：

```powershell
./scrape-lp.ps1 -RenderWithEdge -KeepRawHtml
```

这会额外生成 `page.source.html` 和（Edge 成功时）`page.rendered.raw.html`，它们未经广告清洗，不应作为最终抓取结果。

## 常用参数

指定 CSV 和输出目录：

```powershell
./scrape-lp.ps1 `
  -CsvPath ./adradar_2026-07-14.csv,./adradar_2026-07-15.csv `
  -OutputDirectory D:/lp-data
```

使用 HTTP 代理：

```powershell
./scrape-lp.ps1 -Proxy http://127.0.0.1:7890
```

调整超时、重试和请求间隔：

```powershell
./scrape-lp.ps1 -TimeoutSeconds 90 -RetryCount 5 -DelayMilliseconds 1500
```

成功页面支持断点续跑，再次执行时会直接跳过。要强制重新抓取：

```powershell
./scrape-lp.ps1 -Force
```

如果 VPS 的证书环境异常，可临时加入 `-SkipCertificateCheck`，但不建议长期使用。

## 说明

- 此脚本抓取的是 CSV 中每个 LP URL 对应的页面及其图片资源，不会无限遍历整个域名，避免误抓数万页面。
- 旧版成功结果如果没有“广告已过滤”标记，会自动重新抓取和清洗；不需要手动删除输出目录。
- HTTP 403/429、验证码、登录墙或服务商的浏览器指纹限制仍可能阻止抓取。先尝试 `-RenderWithEdge`，并在 `summary.csv` 和各页面的 `result.json` 中查看失败原因。
- 图片地址会完整保存在 `images.csv`，下载失败不会让整个批次中止。
- 请仅抓取你有权访问和保存的网页，并遵守目标网站条款及当地法律。
