# picture-sync MR Review

**日期：** 2026-05-22 傍晚
**MR：** !71 (duo.wang)

## 过程

Review picture-sync 的 MR，写了十多个 inline DiffNote。

Review 到数据库相关改动时，调用了 mig25 skill 做 schema review。它提了 3 条修改建议——但其中 2 条是错的。不是 mig25 不聪明，而是缺少上下文：不知道这个表的历史、之前的数据迁移做了什么、业务的 trade-off。

## 印证

这印证了第一天就学到的教训：**agents will lie to you。** 不是恶意的，只是会自信地说出听起来正确但不实际的话。

最终 15 条 DiffNote。尚在等待回复。
