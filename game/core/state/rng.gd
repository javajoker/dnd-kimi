# 种子化 RNG（docs/tech/01-技术方案讨论稿.md §5.2 确定性；godot-dev §4）
# 逻辑核内一切随机只允许走本类的种子化实例，禁止裸 randi()。
# 种子与内部状态可入存档（docs/framework/07 §4.1 rng_seed），事件流 + 种子 = 可完整复盘。
class_name Rng
extends RefCounted

var _rng := RandomNumberGenerator.new()
var _seed: int = 0

func _init(seed_value: int = 0) -> void:
	set_seed(seed_value)

## 设种子；同种子必产同序列。
func set_seed(seed_value: int) -> void:
	_seed = seed_value
	_rng.seed = seed_value

func get_seed() -> int:
	return _seed

## d20 检定骰（轻规则包 D20 最小核，05 文档 §2）。
func d20() -> int:
	return d_n(20)

## 1~n 均匀骰。
func d_n(n: int) -> int:
	return _rng.randi_range(1, n)

## [a, b] 闭区间整数。
func range_int(a: int, b: int) -> int:
	return _rng.randi_range(a, b)

## 存档快照：种子 + 内部状态（恢复后续掷与中断前完全一致）。
func save_state() -> Dictionary:
	return {"seed": _seed, "state": _rng.state}

func load_state(snapshot: Dictionary) -> void:
	_seed = int(snapshot.get("seed", 0))
	_rng.seed = _seed
	_rng.state = int(snapshot.get("state", 0))
