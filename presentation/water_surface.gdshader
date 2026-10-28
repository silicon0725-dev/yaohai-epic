// 水面 shader（顶/底通道，双面；侧面变体见 water_side.gdshader）。
// 波形 = Physics Mod（physics-mod-pro v188i，ocean_legacy.glsl）的
// 迭代言波移植：13 次循环 Gerstner 风格分形波——波形 exp(sin-1)
// 非对称尖峰宽谷 + 位置被波拖拽的水平位移（波峰翻卷感），每级
// 频率 x1.18/速度 x1.07/权重 x0.8、方向转 12°。与 CPU 侧
// presentation/ocean_waves.gd 逐行同式（掉落物随波起伏与渲染一致）。
// 保留：太阳反光（Blinn-Phong）、菲涅尔掠射增亮、浪尖白沫、
// 量化坐标的像素波纹色块（体素风）。
// 位移是位置的纯函数（顶面/侧面共享角点同位移，接缝不裂）。
// 纯视觉部分不改水位物理；波高物理联动走 OceanWaves CPU 采样。
shader_type spatial;
render_mode cull_disabled, blend_mix;

uniform vec4 water_color : source_color = vec4(0.09, 0.30, 0.55, 0.68);
// 深浅双色按菲涅尔混（ocean3d_lite 配色思路：近处深色、掠射/远处
// 混向浅色，比单色+提亮更有层次）
// 受光模式（原 UNSHADED 与地形光照语言不一致：阴影投到水上水不变暗）
// 基色调暗补偿光照（太阳 1.2 + 天空环境 ~1.0）
uniform vec3 deep_color : source_color = vec3(0.02, 0.11, 0.23);
uniform vec3 shallow_color : source_color = vec3(0.09, 0.27, 0.44);
// 全局海况缩放（与 OceanWaves.storm_scale 同值，main 每帧同步）
uniform float storm_scale = 1.0;
uniform vec3 sun_direction = vec3(0.4, 0.75, 0.5);
// 波起伏总幅度（格）与时间倍率（Physics Mod oceanHeight/时间缩放）
uniform float wave_amplitude = 1.0;
uniform float wave_speed = 1.0;
// CPU/GPU 同源时钟（main 每帧设置，与 OceanWaves.global_time 同值）
uniform float u_time = 0.0;
// 互动涟漪（WaterRipples 波动方程模拟的输出）：窗口中心与位移/法线强度
uniform sampler2D ripple_map;
uniform vec2 ripple_center = vec2(0.0);
uniform float ripple_window = 16.0;
const float RIPPLE_VERTEX_DISPLACEMENT = 1.1;  // 可见的涟漪环形波
const float RIPPLE_NORMAL_STRENGTH = 4.0;
// 波纹明暗流动的亮度扰动强度
uniform float ripple_strength = 0.09;
// 水面贴图（体素手绘水纹，两层不同方向/速度滚动叠加——MC 水贴图
// 动画的经典做法；参考 Effective/原版 water_still 的贴图流动思路）
uniform sampler2D water_tex : repeat_enable, filter_nearest_mipmap;
uniform float tex_strength = 0.85;
// 高光：强度、锐度；白沫强度
uniform float glint_strength = 0.8;
uniform float glint_shininess = 90.0;
uniform float foam_strength = 0.6;
// 平面反射（真镜像相机）：main 维护一台镜像相机（位置/朝向关于
// 海平面翻转）渲到 SubViewport RT，水面用自身屏幕坐标采样——
// 镜像画面里水面点的位置恰为其真实屏幕位置，几何完全正确
// （水线翻转/raymarch 的近似误差都不存在）；波法线扰动随波晃动
uniform sampler2D sspr_rt : filter_linear_mipmap;
uniform float sspr_water_h = 0.0;
uniform float sspr_strength = 0.7;

varying vec3 world_pos;
// 岸距衰减（网格器烘入的顶点 COLOR.r）：8 邻固体越多越靠岸，
// 波幅越弱——波峰不得越过岸块顶面（穿帮）
varying float shore_fade;

// Physics Mod 迭代言波（13 次循环，逐行对应 ocean_legacy.glsl 的
// physics_waveHeight；factor 固定 1.0）。返回约 [-0.5, 0.5] 波高比，
// 顶点位移 = 返回值 x wave_amplitude。
float wave_field(vec2 p, float t) {
	const int ITERATIONS = 13;
	const float DRAG_MULT = 0.048;
	const float XZ_SCALE = 0.10;  // 波长约 10.5 格（0.035 是 30 格，起伏不可见）
	const float TIME_MULT = 0.9;  // 波速翻倍（原 0.45 浪太慢视觉不可感）
	const float FREQUENCY = 6.0;
	const float SPEED = 2.0;
	const float WEIGHT = 0.8;
	const float FREQUENCY_MULT = 1.18;
	const float SPEED_MULT = 1.07;
	const float ITER_INC = 12.0;
	const float ADJUSTED = 1.0;

	p = p * XZ_SCALE;
	float iter = 0.0;
	float frequency = FREQUENCY;
	float speed = SPEED;
	float weight = 1.0;
	float height = 0.0;
	float wave_sum = 0.0;
	float modified_time = t * TIME_MULT;

	for (int i = 0; i < ITERATIONS; i++) {
		vec2 direction = vec2(sin(iter), cos(iter));
		float x = dot(direction, p) * frequency + modified_time * speed;
		float wave = exp(sin(x) - 1.0);
		float result = wave * cos(x);
		vec2 force = result * weight * direction;
		p -= force * DRAG_MULT * ADJUSTED;
		height += wave * weight;
		iter += ITER_INC;
		wave_sum += weight;
		weight *= WEIGHT;
		frequency *= FREQUENCY_MULT;
		speed *= SPEED_MULT;
	}
	return height / wave_sum - 0.5;
}

// 涟漪高度采样（窗口外为 0，边缘平滑衰减）
float ripple_height(vec2 p) {
	vec2 uv = (p - ripple_center + vec2(ripple_window * 0.5)) / ripple_window;
	vec2 inside = step(vec2(0.0), uv) * step(uv, vec2(1.0));
	float m = inside.x * inside.y;
	float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
	m *= smoothstep(0.0, 0.05, edge);
	// R 通道编码高度（CPU 模拟 RGBA8：h = (r-0.5)*2）
	return (texture(ripple_map, uv).r - 0.5) * 2.0 * m;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shore_fade = COLOR.r;
	// 位移钳制 [-0.16, +0.56]：上涌为主的涌浪——波谷不深陷（防浅滩
	// 露底），波峰受钳与岸衰减共同约束（空间/时间均值实测 ≈-0.03，
	// 反射平面无需为此补偿）
	float displacement = (wave_field(world_pos.xz, u_time * wave_speed)
			* wave_amplitude * storm_scale
			+ ripple_height(world_pos.xz) * RIPPLE_VERTEX_DISPLACEMENT)
			* shore_fade;
	VERTEX.y += clamp(displacement, -0.16, 0.56);
}

void fragment() {
	float t = u_time * wave_speed;
	// 法线：对波高场数值差分（连续坐标，保持平滑）
	float e = 0.09;
	float h0 = wave_field(world_pos.xz, t);
	float hx = wave_field(world_pos.xz + vec2(e, 0.0), t);
	float hz = wave_field(world_pos.xz + vec2(0.0, e), t);
	vec3 normal = normalize(vec3(
			-(hx - h0) * wave_amplitude / e * 6.0 * shore_fade,
			1.0,
			-(hz - h0) * wave_amplitude / e * 6.0 * shore_fade));
	// 涟漪法线扰动（叠加到言波法线上，mod 语义：涟漪以法线表现为主）；
	// 岸边按岸距衰减（位移衰减了，法线扰动同步衰减避免明暗与几何不符）
	float r0 = ripple_height(world_pos.xz) * shore_fade;
	float rx = ripple_height(world_pos.xz + vec2(e, 0.0)) * shore_fade;
	float rz = ripple_height(world_pos.xz + vec2(0.0, e)) * shore_fade;
	normal = normalize(normal + vec3(
			-(rx - r0) / e * RIPPLE_NORMAL_STRENGTH, 0.0,
			-(rz - r0) / e * RIPPLE_NORMAL_STRENGTH));
	// 世界法线 -> 视图空间，交给场景光照（波峰亮波谷暗的真实 shading）
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);
	ROUGHNESS = 0.12;
	SPECULAR = 0.5;

	vec3 cam_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_dir = normalize(cam_world - world_pos);
	vec3 sun_dir = normalize(sun_direction);

	// 太阳反光（Blinn-Phong）+ 菲涅尔（掠射增亮）
	vec3 half_v = normalize(view_dir + sun_dir);
	float glint = pow(max(dot(normal, half_v), 0.0), glint_shininess)
			* glint_strength;
	float fresnel = pow(1.0 - max(dot(view_dir, normal), 0.0), 3.0);

	// 水面贴图层：两层不同方向速度的世界坐标滚动采样叠加
	vec2 uv1 = world_pos.xz * 0.22 + vec2(u_time * 0.031, u_time * 0.023);
	vec2 uv2 = world_pos.xz * 0.37 + vec2(-u_time * 0.019, u_time * 0.027);
	float tex_l1 = texture(water_tex, uv1).r - 0.5;
	float tex_l2 = texture(water_tex, uv2).r - 0.5;
	vec2 tex_flow = vec2(tex_l1 * 0.6 + tex_l2 * 0.4);

	// 波纹明暗流动（连续坐标——不量化，避免近看的方块像素感）
	vec2 pw = world_pos.xz * 3.7;
	float ripple = sin(pw.x + t * 1.05) * sin(pw.y * 1.27 - t * 0.87)
			+ 0.55 * sin((pw.x + pw.y) * 0.72 + t * 0.66)
			+ 0.35 * sin((pw.x - pw.y) * 0.95 - t * 1.27);

	// 浪尖白沫：波峰 + 连续高频噪声破碎（同样不量化）
	float crest = smoothstep(0.22, 0.40, h0);
	float foam_noise = 0.5 + 0.5 * sin(pw.x * 2.6 + t * 2.3)
			* sin(pw.y * 3.1 - t * 1.9);
	foam_noise *= 0.65 + (tex_l2 + 0.5);  // 贴图颗粒破碎白沫
	float foam = crest * foam_strength * foam_noise;

	vec3 albedo = mix(deep_color, shallow_color, fresnel)
			+ (water_color.rgb * 1.4 + 0.08) * tex_flow.x * tex_strength
			+ ripple_strength * ripple * 0.35;
	albedo = mix(albedo, vec3(0.88), foam);
	// 平面反射：采样镜像相机 RT（SCREEN_UV 即镜像画面中本点的位置）
	// h_gate 只拦"远离海平面的高处流水"（|Δ|>0.6 渐隐、1.5 全关——
	// 山坡瀑布不镜像）。低水位坑水（level 1~4，Δ=0.1~0.55）必须保持
	// 全反射：按 |Δ| 收紧会把这些水的反射压没（"反射消失"实机反馈，
	// 用户测试区正是凹坑水位），其轻微视差错位换取反射存在感
	float h_gate = 1.0 - smoothstep(0.6, 1.5, abs(world_pos.y - sspr_water_h));
	// 镜像相机 = 数学镜像基（逐列 y 翻转）x 列取反补右手性——其画面
	// 相对正确倒影图是水平翻转，采样 1-uv.x 精确还原点对应（任意俯角
	// 成立；up 正交化构造低头会退化——已踩坑）
	// 波法线扰动按相机距离归一：固定 uv 偏移是角度量，世界偏移随距离
	// 线性放大（远岸 1~2 格，倒影飘离水线——实机踩坑）；0.3/dist 让
	// 世界晃幅恒定 ≈0.3 格（近岸 clamp 6 不超原幅度）
	float cam_dist = length(world_pos
			- (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	vec2 uv_ref = clamp(vec2(1.0 - SCREEN_UV.x, SCREEN_UV.y)
			+ normal.xz * (0.3 / max(cam_dist, 6.0)),
			vec2(0.001), vec2(0.999));
	vec3 refl = texture(sspr_rt, uv_ref).rgb;
	// 水体滤色（海洋渲染标准做法）：反射色向水色偏移——掠射时反射
	// 主体是亮天空，不滤色会把水面刷成牛奶白（已踩坑）；FILMIC 后
	// 天空/亮沙亮度几乎相同（0.62/0.60 实测），按亮度区分内容不可行
	refl = refl * vec3(0.65, 0.8, 1.0);
	refl = mix(refl, deep_color * 2.0, 0.22);
	float refl_w = clamp(h_gate * sspr_strength
			* (0.15 + 0.5 * fresnel) * (1.0 - foam * 0.8), 0.0, 1.0);
	// 岸线裙边淡出：水面网格在岸线角点斜降 1 格到岸格底（防裂缝裙边），
	// 该带 world_pos.y 低于反射平面 → 反射采样渐变错位（"倒影与水线断
	// 层 / 多显示一格水下方块"实机踩坑）。淡出区间只盖真正的贴岸角点
	// （shore_fade≤0.2，1 个固体邻的角点 0.5 不受影响——v35 的 0.35
	// 区间近岸大面积压反射，"反射消失"实机反馈）
	refl_w *= smoothstep(0.0, 0.2, shore_fade);
	albedo = mix(albedo, refl, refl_w);
	ALBEDO = albedo;
	EMISSION = vec3(glint * 0.8);  // 波光耀斑不受场景光照二次调制
	// 掠射不再增不透明度（fresnel*0.25 会在掠射把 alpha 推到 0.93，
	// 叠反射色成大块不透明奶白——实机踩坑）；反射负责掠射增亮
	ALPHA = clamp(water_color.a + foam * 0.6, 0.0, 0.95);
}
