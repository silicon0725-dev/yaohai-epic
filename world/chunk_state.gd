## 区块生命周期状态（开发文档 §4.4）。
## Stage A 为同步流水线，只走 DATA_READY -> MESH_QUEUED -> MESH_READY -> ACTIVE；
## 异步任务的版本号与过期任务检查在阶段 C（流式加载）引入。
class_name ChunkState
extends RefCounted

enum State {
	UNLOADED,
	QUEUED,
	GENERATING,
	DATA_READY,
	MESH_QUEUED,
	MESH_READY,
	ACTIVE,
	EVICT_PENDING,
}
