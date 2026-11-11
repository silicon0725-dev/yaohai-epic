## 动作编辑器数据层（纯逻辑可测）：播放队列/段级修剪与倍速/区间事件
## 扫掠（OnEnter/OnExit 成对）/seek 定位/播放头。
## 概念借鉴 CwcMontage（Unity，仅设计参考）：资产只存时间区间划分，
## 运行时按段映射采样；事件半开区间 (prev, curr] 扫掠防漏帧。
extends RefCounted

## 队列项：{"clip": String, "t0": float, "t1": float, "speed": float,
##          "src_length": float, "events": [{"t0": float, "t1": float,
##          "name": String}]（事件为段内源时间轴）}
var queue: Array = []
var playhead := 0.0     # 队列全局时间（秒，含倍速折算后的表观时长）
var speed := 1.0        # 全局倍率（段级 speed 与之相乘）
var looping := false

signal queue_changed
signal playhead_moved


func clear() -> void:
	queue.clear()
	playhead = 0.0
	queue_changed.emit()


## 追加动作（src_length=源 clip 时长；默认全段原速）。
func append(clip_name: String, src_length: float) -> void:
	queue.append({"clip": clip_name, "t0": 0.0, "t1": src_length,
			"speed": 1.0, "src_length": src_length, "events": []})
	queue_changed.emit()


func remove_at(index: int) -> void:
	if index >= 0 and index < queue.size():
		queue.remove_at(index)
		playhead = clampf(playhead, 0.0, total_length())
		queue_changed.emit()


## 段表观时长 =（出点-入点）/段速。
func item_length(item: Dictionary) -> float:
	return maxf((float(item["t1"]) - float(item["t0"]))
			/ maxf(float(item["speed"]), 0.05), 0.05)


func total_length() -> float:
	var t := 0.0
	for item in queue:
		t += item_length(item)
	return t


## 全局时间 → {index, local_t}；越界返回空。
func locate(t: float) -> Dictionary:
	var acc := 0.0
	for i in queue.size():
		var item: Dictionary = queue[i]
		var len_i := item_length(item)
		if t < acc + len_i or i == queue.size() - 1:
			return {"index": i, "local_t": clampf(t - acc, 0.0, len_i)}
		acc += len_i
	return {}


## 段内表观时间 → 源时间（入点+表观×段速，钳出点）。
func source_time(item: Dictionary, local_t: float) -> float:
	var src: float = float(item["t0"]) \
			+ local_t * maxf(float(item["speed"]), 0.05)
	return clampf(src, float(item["t0"]), float(item["t1"]))


## 推进播放头；返回 {"switch_to": index} 当跨段（含循环回卷）。
func advance(delta: float) -> Dictionary:
	if queue.is_empty():
		return {}
	playhead += delta * speed
	var total := total_length()
	if playhead >= total:
		if looping:
			var switch := locate(playhead - total)
			playhead = fmod(playhead, maxf(total, 1e-4))
			playhead_moved.emit()
			return {"switch_to": switch.get("index", 0)}
		playhead = total
		playhead_moved.emit()
		return {}
	var loc := locate(playhead)
	playhead_moved.emit()
	return {"switch_to": loc.get("index", -1)}


## seek 到全局时间（返回目标段 index）。
func seek(t: float) -> int:
	playhead = clampf(t, 0.0, total_length())
	var loc := locate(playhead)
	playhead_moved.emit()
	return loc.get("index", -1)


func current_index() -> int:
	var loc := locate(playhead)
	return loc.get("index", -1)


## 区间事件扫掠：表观 local 时间从 prev→curr 跨入/跨出事件区间。
## 半开区间 (prev, curr] 判定（CwcMontage 同思路：低帧率不漏触发、
## OnEnter/OnExit 严格成对）。返回 [{"event": Dictionary, "phase": "enter"|"exit"}]。
func sweep_events(item: Dictionary, prev_local: float,
		curr_local: float) -> Array:
	var out := []
	var events: Array = item.get("events", [])
	# 段速折算到表观时间轴比较
	var spd := maxf(float(item["speed"]), 0.05)
	for ev in events:
		var e0: float = (float(ev["t0"]) - float(item["t0"])) / spd
		var e1: float = (float(ev["t1"]) - float(item["t0"])) / spd
		# enter：prev <= e0 < curr（正向跨入）
		if prev_local <= e0 and e0 < curr_local:
			out.append({"event": ev, "phase": "enter"})
		# exit：prev < e1 <= curr（跨出）
		if prev_local < e1 and e1 <= curr_local:
			out.append({"event": ev, "phase": "exit"})
	return out


## 导出蒙太奇资产（var_to_str 可读文本）。
func export_montage(name: String) -> Dictionary:
	return {"name": name, "items": queue.duplicate(true)}


func import_montage(data: Dictionary) -> bool:
	if not (data is Dictionary) or not data.has("items"):
		return false
	queue.clear()
	for item in data["items"]:
		if item is Dictionary and item.has("clip"):
			var it: Dictionary = {
				"clip": String(item["clip"]),
				"t0": float(item.get("t0", 0.0)),
				"t1": float(item.get("t1", 1.0)),
				"speed": float(item.get("speed", 1.0)),
				"src_length": maxf(float(item.get("src_length",
						item.get("t1", 1.0))),
						float(item.get("t1", 1.0))),
				"events": [],
			}
			for ev in item.get("events", []):
				it["events"].append({
					"t0": float(ev.get("t0", 0.0)),
					"t1": float(ev.get("t1", 0.2)),
					"name": String(ev.get("name", "evt")),
				})
			queue.append(it)
	playhead = 0.0
	queue_changed.emit()
	return true
