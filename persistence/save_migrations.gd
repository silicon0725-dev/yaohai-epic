## 存档版本迁移框架（开发文档 §9.3、§5.1）。
## MVP 策略：区块存档为完整数据（与生成算法无关），生成版本变化
## 只影响未修改区域的地形重建；格式版本不向前兼容（高版本存档拒读）。
## 未来真正的数据迁移（如方块改名映射）在此扩展。
class_name SaveMigrations
extends RefCounted

## 当前程序能理解的存档格式版本集合。
const KNOWN_FORMAT_VERSIONS := [1]


## 存档格式是否可读。未知高版本：拒读（避免静默误读）。
static func is_format_compatible(format_version: int) -> bool:
	return KNOWN_FORMAT_VERSIONS.has(format_version)


## 生成算法版本是否与当前一致。不一致并非错误：
## 完整区块数据不受影响，只有未修改区域会用新算法重建（§5.1）。
## 返回 true 表示完全一致；不一致时调用方应给出明确告警。
static func is_generator_current(meta: Dictionary) -> bool:
	return int(meta.get("generator_version", -1)) \
			== TerrainGenerator.GENERATOR_VERSION
