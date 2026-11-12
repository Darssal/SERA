# SERA 项目图稿

图稿根据 2.2.1+33 源码整理。业务节点使用独立方框，判断使用菱形，时序图实线表示请求、虚线表示返回。

[下载可编辑 Visio 文件](diagrams/SERA-system-diagrams.vsdx) · [查看使用海报](images/sera-poster.png)

| 图稿 | 实现依据 |
| --- | --- |
| [功能模块](diagrams/fig2-1-modules.svg) | [ARCHITECTURE.md](../sera_flutter/docs/ARCHITECTURE.md) |
| [系统架构](diagrams/fig2-2-architecture.svg) | [ARCHITECTURE.md](../sera_flutter/docs/ARCHITECTURE.md) |
| [领域对象](diagrams/fig2-3-domain.svg) | [models.dart](../sera_flutter/lib/domain/models.dart) |
| [数据分区](diagrams/fig2-4-storage.svg) | [workspace_store.py](../sera_flutter/backend/workspace_store.py) |
| [草案确认](diagrams/fig3-19-flow.svg) | [sera_controller.dart](../sera_flutter/lib/application/sera_controller.dart) |
| [语音与语义理解](diagrams/fig3-21-voice.svg) | [asr_service.py](../sera_flutter/backend/asr_service.py) |
| [约束排期](diagrams/fig3-22-scheduling.svg) | [planning_service.dart](../sera_flutter/lib/domain/planning_service.dart) |
| [离线同步](diagrams/fig3-20-sync.svg) | [offline_repository.dart](../sera_flutter/lib/data/offline_repository.dart) |
| [完成与撤销](diagrams/fig3-24-undo.svg) | [task_completion_undo_test.dart](../sera_flutter/test/task_completion_undo_test.dart) |
| [社区图文发布](diagrams/fig3-25-publish.svg) | [community_store.py](../sera_flutter/backend/community_store.py) |
| [管理授权与审计](diagrams/fig5-1-admin.svg) | [admin_store.py](../sera_flutter/backend/admin_store.py) |
| [静态缓存更新](diagrams/fig5-5-cache.svg) | [sera-sw.js](../sera_flutter/web/sera-sw.js) |
| [单主机部署](diagrams/fig5-6-deployment.svg) | [compose.yaml](../sera_flutter/deploy/compose.yaml) |
| [缓存复用结果](diagrams/fig5-7-cache-results.svg) | [ADMIN_ANALYTICS_QA_20261110.md](../sera_flutter/docs/ADMIN_ANALYTICS_QA_20261110.md) |

结构表达参考 [C4 图形标注](https://c4model.com/diagrams/notation)与 [Argo CD 架构文档](https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/architecture.md)，按 SERA 的实际组件和调用关系绘制。海报以项目运行界面为参考制作。
