# 关键判定 3D D20 物理演出（docs/framework/14-表现层与平台化清单.md #2；
# 09 §6 关键级"全屏物理演出"；04 §3.2 骰子系统；04 §④.7 长按跳过由壳层仲裁）。
# 铁律边界：
# - 结果由逻辑层给定（play(result) 的参数就是事件流里的 keep 值）——物理只是演出，
#   落定时把"目标数字所在面"定向到顶面（最短弧对齐），绝不允许物理决定结果
#   （与付费禁区同源的骰子公正性：物理是表演，事件流是唯一真相，09 §6）；
# - 纯呈现：不读写 Board、不发事件流、不引用 core 判定路径；皮肤只经 Cosmetics.palette_of 取色
#   （06 §3/§7：换肤 = 换调色板）；演出视觉随机走种子化 Rng（godot-dev §4），与逻辑骰无关；
# - time_scale 慢镜头是全局旋钮：恢复责任在本类（定格/跳过/析构三处兜底恢复）。
class_name Dice3D
extends Control

signal finished(result: int)

## 演出速率（1.0 = 正式节奏；测试/截图注入更大值压缩等待，物理弹道不变）。
var speed: float = 1.0

const DIE_RADIUS := 0.62          # 二十面体外接球半径（米级桌面布景）
const TABLE_TOP := 0.0            # 桌面上表面高度
const SLOW_MO_SCALE := 0.3        # 慢镜头档位（14 #2：Engine.time_scale 渐变 0.3）
const THROW_MIN := 1.5            # 弹跳最短时长（秒，14 #2：1.5~2s）
const THROW_MAX := 2.0            # 弹跳上限，到点强制收束（物理只做表演）
const ALIGN_TIME := 0.5           # 慢镜头内定格对齐时长

var _sub: SubViewport
var _camera: Camera3D
var _die: RigidBody3D
var _die_mesh: MeshInstance3D
var _edge_mat: StandardMaterial3D # 边缘光（grow 描边 + 自发光金）
var _body_mat: StandardMaterial3D
var _num_labels: Array[Label3D] = []

var _verts: Array[Vector3] = []   # 12 顶点（局部系）
var _faces: Array = []            # 20 面，每面 3 顶点索引
var _face_normals: Array[Vector3] = []
var _face_values: Array[int] = [] # 面 → 数字（对面和为 21 标准编号）
var _value_face: Dictionary = {}  # 数字 → 面索引

var _playing := false
var _skip := false
var _settled := false
var _target := 0
var _prev_time_scale := 1.0
var _time_tween: Tween = null
var _camera_base_fov := 55.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE # 长按跳过由壳层 overlay 统一仲裁（04 §④.7）
	_build_geometry()
	_build_stage()
	resized.connect(_fit_viewport)
	_fit_viewport()

# ---------------------------------------------------------------- 几何（程序化二十面体，无外部模型资源）

## 正二十面体：12 顶点 = (±1,±t,0)/(0,±1,±t)/(±t,0,±1)，t=黄金分割；20 面索引经典表，
## 绕序统一翻正为外法线；编号按 D20 标准"对面和为 21"（法线近反向的两面配对）。
func _build_geometry() -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var raw := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for v: Vector3 in raw:
		_verts.append(v.normalized() * DIE_RADIUS)
	var idx := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for f: Array in idx:
		var a: Vector3 = _verts[f[0]]
		var b: Vector3 = _verts[f[1]]
		var c: Vector3 = _verts[f[2]]
		var n := (b - a).cross(c - a).normalized()
		if n.dot((a + b + c) / 3.0) < 0.0: # 绕序翻正：法线必须朝外
			f = [f[0], f[2], f[1]]
			n = -n
		_faces.append(f)
		_face_normals.append(n)
	_number_faces()

## 对面配对（法线点积 < -0.99）→ 第 k 对取值 (k+1, 20-k)，对面和恒 21。
func _number_faces() -> void:
	_face_values.resize(_faces.size())
	var visited: Array = []
	visited.resize(_faces.size())
	for i: int in visited.size():
		visited.append(false)
	var pair := 0
	for i: int in _faces.size():
		if visited[i]:
			continue
		var j := -1
		for k: int in _faces.size():
			if k != i and not visited[k] and _face_normals[i].dot(_face_normals[k]) < -0.99:
				j = k
				break
		visited[i] = true
		_face_values[i] = pair + 1
		_value_face[pair + 1] = i
		if j >= 0:
			visited[j] = true
			_face_values[j] = 20 - pair
			_value_face[20 - pair] = j
		pair += 1

# ---------------------------------------------------------------- 舞台（桌面/灯光/相机/环境，全程序化）

func _build_stage() -> void:
	var container := SubViewportContainer.new()
	container.name = "ViewportContainer"
	container.stretch = false # 尺寸由 _fit_viewport 手写 1:1（stretch=true 禁改 SubViewport.size）
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_sub = SubViewport.new()
	_sub.name = "Sub"
	_sub.own_world_3d = true
	_sub.transparent_bg = false
	container.add_child(_sub)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.22, 0.20, 0.28)
	env.ambient_light_energy = 0.9
	env.glow_enabled = true # 边缘光泛光（金墨高光，小剂量防糊面）
	env.glow_intensity = 0.3
	env.glow_bloom = 0.04
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env_node.environment = env
	_sub.add_child(env_node)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = _camera_base_fov
	_sub.add_child(_camera)
	_camera.look_at_from_position(Vector3(0, 4.7, 6.3), Vector3(0, 0.3, 0), Vector3.UP)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.light_color = Color(1.0, 0.88, 0.62) # 金色主光
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	_sub.add_child(sun)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-2.4, 2.6, -1.8)
	rim.light_color = Color(0.45, 0.55, 1.0) # 冷色轮廓补光，衬金墨
	rim.light_energy = 0.7
	rim.omni_range = 8.0
	_sub.add_child(rim)

	# 桌面（墨色绒面 + 金边底盘）
	var table := StaticBody3D.new()
	table.name = "Table"
	_sub.add_child(table)
	var felt := MeshInstance3D.new()
	var felt_mesh := BoxMesh.new()
	felt_mesh.size = Vector3(11, 0.4, 8.4)
	felt.mesh = felt_mesh
	var felt_mat := StandardMaterial3D.new()
	felt_mat.albedo_color = Color(0.05, 0.05, 0.10)
	felt_mat.roughness = 0.9
	felt.material_override = felt_mat
	felt.position = Vector3(0, TABLE_TOP - 0.2, 0)
	table.add_child(felt)
	var trim := MeshInstance3D.new()
	var trim_mesh := BoxMesh.new()
	trim_mesh.size = Vector3(11.5, 0.16, 8.9)
	trim.mesh = trim_mesh
	var trim_mat := StandardMaterial3D.new()
	trim_mat.albedo_color = Color(0.36, 0.26, 0.08)
	trim_mat.metallic = 0.9
	trim_mat.roughness = 0.35
	trim_mat.emission_enabled = true
	trim_mat.emission = Color(0.55, 0.38, 0.10)
	trim_mat.emission_energy_multiplier = 0.35
	trim.material_override = trim_mat
	trim.position = Vector3(0, TABLE_TOP - 0.44, 0)
	table.add_child(trim)
	var table_col := CollisionShape3D.new()
	var table_box := BoxShape3D.new()
	table_box.size = Vector3(11, 0.4, 8.4)
	table_col.shape = table_box
	table_col.position = felt.position
	table.add_child(table_col)
	# 隐形围挡：骰不出画（物理仍只是表演，围挡保证收束在镜头内）
	for w: Array in [[Vector3(5.6, 1.5, 0), Vector3(0.2, 3.4, 8.8)],
			[Vector3(-5.6, 1.5, 0), Vector3(0.2, 3.4, 8.8)],
			[Vector3(0, 1.5, 4.3), Vector3(11.6, 3.4, 0.2)],
			[Vector3(0, 1.5, -4.3), Vector3(11.6, 3.4, 0.2)]]:
		var wall_col := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = w[1]
		wall_col.shape = wall_box
		wall_col.position = w[0]
		table.add_child(wall_col)

	# D20 本体：RigidBody + 凸包碰撞 + 程序化网格 + 20 枚金字面片
	_die = RigidBody3D.new()
	_die.name = "Die"
	_die.mass = 0.9
	var phys := PhysicsMaterial.new()
	phys.bounce = 0.42
	phys.friction = 0.55
	_die.physics_material_override = phys
	_die.can_sleep = true
	_die.visible = false
	_die.freeze = true
	_sub.add_child(_die)
	var col := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array(_verts)
	col.shape = hull
	_die.add_child(col)
	_die_mesh = MeshInstance3D.new()
	_die_mesh.mesh = _build_die_mesh()
	_die.add_child(_die_mesh)
	_build_number_labels()

## 逐面独立顶点（平直着色）；墨面本体 + 材质级 rim 边缘光（菲涅尔轮廓光，
## 金色主光勾边——比反壳 grow 方案稳，不糊面）。
func _build_die_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in _faces.size():
		var f: Array = _faces[i]
		st.set_normal(_face_normals[i])
		for k: int in 3:
			st.add_vertex(_verts[f[k]])
	var mesh := st.commit()
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.07, 0.06, 0.12)
	_body_mat.metallic = 0.35
	_body_mat.roughness = 0.32
	_body_mat.rim_enabled = true # 边缘光（14 #2 金墨配色 + 边缘光）
	_body_mat.rim = 1.0
	_body_mat.rim_tint = 0.2
	_edge_mat = StandardMaterial3D.new() # 备用描边壳（默认不启用，皮肤扩展位）
	_edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_edge_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_edge_mat.grow = true
	_edge_mat.grow_amount = 0.014
	_edge_mat.albedo_color = Color(0.91, 0.78, 0.42)
	mesh.surface_set_material(0, _body_mat)
	return mesh

## 面片文字：Label3D 贴面心外法线方向（程序化编号，无需贴图资源）。
func _build_number_labels() -> void:
	var inradius := DIE_RADIUS * 0.79465 # 二十面体内切球半径比
	for i: int in _faces.size():
		var n: Vector3 = _face_normals[i]
		var lbl := Label3D.new()
		lbl.text = str(_face_values[i])
		lbl.font_size = 220
		lbl.pixel_size = 0.0022
		lbl.modulate = Color(0.93, 0.80, 0.45)
		lbl.outline_size = 26
		lbl.outline_modulate = Color(0.10, 0.07, 0.02)
		lbl.double_sided = false
		lbl.no_depth_test = false
		lbl.position = n * (inradius + 0.012)
		lbl.basis = _facing_basis(n)
		_die.add_child(lbl)
		_num_labels.append(lbl)

## 局部基：+Z = 面外法线（Label3D 正面朝 +Z），文字上方尽量朝世界上方。
static func _facing_basis(n: Vector3) -> Basis:
	var z := n.normalized()
	var hint := Vector3.UP if absf(z.y) < 0.95 else Vector3.FORWARD
	var x := hint.cross(z).normalized()
	var y := z.cross(x)
	return Basis(x, y, z).orthonormalized()

# ---------------------------------------------------------------- 对外 API（壳层唯一入口）

## 开始演出：result = 逻辑层已定的骰值（1~20，事件流 keep）；seed 只驱动视觉弹道；
## palette = Cosmetics.palette_of 调色板（换肤只换色，06 §3/§4）。
func play(result: int, seed: int, palette: Dictionary = {}) -> void:
	if _playing:
		return
	_target = clampi(result, 1, 20)
	_apply_palette(palette)
	_run(seed)

func is_playing() -> bool:
	return _playing

## 长按跳过（壳层仲裁后调用）：立即定格到目标顶面并恢复时间，同步完成不拖拍。
func request_skip() -> void:
	if not _playing or _settled:
		return
	_skip = true

## 当前顶面数字（世界 +Y 点积最大的面）；测试断言口：落定后必等于 play 的 result。
func top_face() -> int:
	if _die == null:
		return -1
	var b := _die.global_transform.basis.orthonormalized()
	var best := -1
	var best_y := -2.0
	for i: int in _face_normals.size():
		var y := (b * _face_normals[i]).y
		if y > best_y:
			best_y = y
			best = i
	return _face_values[best] if best >= 0 else -1

func face_count() -> int:
	return _faces.size()

## 编号合规：20 面恰为 1~20 且对面和 21（测试断言口）。
func face_values_valid() -> bool:
	if _faces.size() != 20 or _value_face.size() != 20:
		return false
	for v: int in range(1, 21):
		if not _value_face.has(v):
			return false
		var f: int = _value_face[v]
		var opp := -1
		for k: int in _faces.size():
			if k != f and _face_normals[f].dot(_face_normals[k]) < -0.99:
				opp = k
				break
		if opp < 0 or _face_values[opp] != 21 - v:
			return false
	return true

# ---------------------------------------------------------------- 演出流程（物理是表演，结果早定）

func _run(seed: int) -> void:
	_playing = true
	_skip = false
	_settled = false
	_prev_time_scale = Engine.time_scale
	_throw(seed)
	# ① 自由弹跳 1.5~2s（/speed 压缩等待；物理弹道本身不吃 speed）
	var visual := Rng.new(seed)
	var fly_min := visual.range_int(int(THROW_MIN * 100), int(THROW_MAX * 100)) / 100.0 / speed
	var fly_cap := (THROW_MAX + 0.6) / speed
	var t := 0.0
	while t < fly_min or (t < fly_cap and not _nearly_still()):
		if _skip:
			break
		await get_tree().physics_frame
		t += get_physics_process_delta_time() # 弹跳段 time_scale=1，步长即墙钟
	if not _skip:
		# ② 慢镜头（time_scale 渐变 0.3）+ 定格对齐目标顶面
		_die.freeze = true
		_tween_time_scale(SLOW_MO_SCALE, 0.14 / speed)
		await _align_to_target(ALIGN_TIME / speed)
	if not _skip:
		_tween_time_scale(_prev_time_scale, 0.10 / speed)
		await get_tree().create_timer(0.10 / speed).timeout
	_settle_now()

## 随机初速 + 角速度抛出（视觉随机走种子化 Rng，与逻辑骰无关）。
func _throw(seed: int) -> void:
	var visual := Rng.new(seed)
	_die.freeze = false
	_die.visible = true
	_die.sleeping = false
	_die.position = Vector3(visual.range_int(-14, 14) / 10.0, 4.4,
		visual.range_int(-10, 10) / 10.0)
	_die.rotation = Vector3(visual.range_int(0, 628) / 100.0,
		visual.range_int(0, 628) / 100.0, visual.range_int(0, 628) / 100.0)
	_die.linear_velocity = Vector3(visual.range_int(-16, 16) / 10.0,
		-2.2, visual.range_int(-8, 8) / 10.0)
	_die.angular_velocity = Vector3(visual.range_int(-90, 90) / 10.0,
		visual.range_int(-90, 90) / 10.0, visual.range_int(-90, 90) / 10.0)

func _nearly_still() -> bool:
	return _die.sleeping \
		or (_die.linear_velocity.length() < 0.35 and _die.angular_velocity.length() < 0.6)

## 定格对齐：最短弧旋转把目标面法线转到世界 +Y（"对齐最近顶点到目标值"），
## 位置收束到桌面静息高度 + 镜头推近；全程慢镜头遮盖演出接缝（结果物理零参与）。
func _align_to_target(duration: float) -> void:
	var face: int = _value_face[_target]
	var b0 := _die.global_transform.basis.orthonormalized()
	var n_world := (b0 * _face_normals[face]).normalized()
	var q0 := b0.get_rotation_quaternion()
	var q1 := (Basis(Quaternion(n_world, Vector3.UP)) * b0).get_rotation_quaternion().normalized()
	var rest := _die.position
	var min_y := INF
	for v: Vector3 in _verts:
		min_y = minf(min_y, (Basis(q1) * v).y)
	rest.y = TABLE_TOP - min_y + 0.002
	rest.x = clampf(rest.x * 0.45, -2.2, 2.2) # 定格收拢到镜头中心（仪式感构图）
	rest.z = clampf(rest.z * 0.45, -1.5, 1.5)
	var from := _die.position
	var elapsed := 0.0
	while elapsed < duration:
		if _skip:
			return
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		var k := smoothstep(0.0, 1.0, clampf(elapsed / duration, 0.0, 1.0))
		_die.basis = Basis(q0.slerp(q1, k)).orthonormalized()
		_die.position = from.lerp(rest, k)
		_camera.fov = lerpf(_camera_base_fov, 46.0, k)
	_die.basis = Basis(q1).orthonormalized()
	_die.position = rest
	_die.linear_velocity = Vector3.ZERO
	_die.angular_velocity = Vector3.ZERO

## 定格兜底：跳过/异常路径同步完成——瞬间对齐、时间恢复、发 finished。
func _settle_now() -> void:
	if _settled:
		return
	_settled = true
	_die.freeze = true
	var face: int = _value_face[_target]
	var b0 := _die.global_transform.basis.orthonormalized()
	var n_world := (b0 * _face_normals[face]).normalized()
	_die.basis = (Basis(Quaternion(n_world, Vector3.UP)) * b0).orthonormalized()
	var min_y := INF
	for v: Vector3 in _verts:
		min_y = minf(min_y, (_die.basis * v).y)
	_die.position.y = TABLE_TOP - min_y + 0.002
	_die.position.x = clampf(_die.position.x, -4.2, 4.2)
	_die.position.z = clampf(_die.position.z, -3.0, 3.0)
	_die.linear_velocity = Vector3.ZERO
	_die.angular_velocity = Vector3.ZERO
	_camera.fov = 46.0
	_restore_time_scale()
	_playing = false
	var result := _target
	finished.emit(result)

func _tween_time_scale(target: float, duration: float) -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	_time_tween = create_tween()
	_time_tween.tween_property(Engine, "time_scale", target, maxf(duration, 0.01))

func _restore_time_scale() -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	Engine.time_scale = _prev_time_scale

func _exit_tree() -> void:
	if Engine.time_scale != _prev_time_scale:
		Engine.time_scale = _prev_time_scale # 兜底：演出中析构不得留下慢镜头

# ---------------------------------------------------------------- 皮肤（只读调色板，渲染对规则无感）

func _apply_palette(pal: Dictionary) -> void:
	if pal.is_empty():
		return
	var face: Color = pal.get("face", Color(0.93, 0.80, 0.45))
	var pip: Color = pal.get("pip", Color(0.10, 0.08, 0.05))
	for lbl: Label3D in _num_labels:
		lbl.modulate = face
		lbl.outline_modulate = pip.darkened(0.4)
	_edge_mat.albedo_color = face # 备用描边壳随肤（默认不启用）
	_body_mat.albedo_color = pip.darkened(0.35).lerp(Color(0.07, 0.06, 0.12), 0.4)

func _fit_viewport() -> void:
	if _sub == null:
		return
	var s := size
	if s.x < 8.0 or s.y < 8.0:
		s = get_viewport_rect().size
	_sub.size = Vector2i(maxi(int(s.x), 8), maxi(int(s.y), 8))
