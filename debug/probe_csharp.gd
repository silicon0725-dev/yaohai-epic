extends SceneTree
## headless C# 可用性探针：确认 .NET 运行时与 NativeMesher 实例化是否成功。

func _init() -> void:
	var script: CSharpScript = load("res://native/NativeMesher.cs") as CSharpScript
	if script == null:
		print("PROBE script=null (load failed)")
		quit(1)
		return
	print("PROBE script loaded: ", script.resource_path)
	var inst: RefCounted = script.new() as RefCounted
	if inst == null:
		print("PROBE new()=null (instantiation failed)")
		quit(1)
		return
	print("PROBE instance: ", inst.get_class())
	if inst.has_method("get_version"):
		print("PROBE version: ", inst.call("get_version"))
	print("PROBE OK")
	quit(0)
