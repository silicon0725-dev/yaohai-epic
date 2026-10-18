## 轻量测试基类（开发文档 §11.1）。
## 不依赖 GUT 等第三方框架；headless 运行方式见 tests/run_all_tests.gd。
class_name VoxelTestCase
extends RefCounted

var check_count := 0
var failures: Array[String] = []


## 子类覆盖此方法执行测试。
func run() -> void:
	push_error("VoxelTestCase.run() 未被子类覆盖")
	failures.append("run() 未实现")


func check(condition: bool, label: String) -> void:
	check_count += 1
	if not condition:
		failures.append(label)


func check_eq(actual: Variant, expected: Variant, label: String) -> void:
	check_count += 1
	if actual != expected:
		failures.append("%s — 期望 %s，实际 %s" % [label, str(expected), str(actual)])


func summary() -> String:
	if failures.is_empty():
		return "PASS（%d 项检查）" % check_count
	return "FAIL（%d/%d 项失败）:\n  - %s" % [
		failures.size(), check_count, "\n  - ".join(PackedStringArray(failures))]
