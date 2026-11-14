// 地形表面着色器：等价 StandardMaterial3D（图集 albedo + Nearest + 顶点
// 色调制 + roughness 1），并支持反射 RT 的水下裁剪——镜像相机（位置每
// 帧下发）渲染时丢弃水面以下的片元。玩家站岸上时镜像相机埋在岸体地下，
// 不裁会把地下方块内壁拍进倒影（实机踩坑：倒影出现水下 1~2 格场景）。
shader_type spatial;

uniform sampler2D atlas : source_color, filter_nearest;
// 树叶镂空（cutout）：alpha 裁切让贴图透明孔洞成真洞
uniform bool cutout_mode = false;
// RT pass 判别：INV_VIEW_MATRIX[3] 是当前渲染相机的世界位置，与镜像相
// 机位置一致即正在渲染反射 RT（主相机在水上、镜像相机在水下，不会误判）
uniform vec3 sspr_mirror_cam_pos = vec3(1.0e9, 1.0e9, 1.0e9);
uniform float sspr_clip_y = 0.0;
// 日夜天光系数（main 每帧下发）：天光顶点色（COLOR.a = s³）乘此系数
// 得夜暗；方块光暖色（COLOR.rgb）不乘——夜晚火把/提灯自动接管
uniform float u_day = 1.0;
// 风摆（植被专属；main 每帧下发时间）：网格器把 (权重,相位) 烘进 UV2——
// 底 0 顶 1（平方衰减=根不动梢摆）。火把无 UV2=0 天然不摆。主摆+叶尖
// 微颤双频（GrassierGrass 动画模型的顶点着色器廉价版：零 compute/
// SSBO，相位与空间波前让相邻叶片连贯成浪）
uniform float u_wind_time = 0.0;

varying vec3 wpos;

// 双 sin 伪 value-noise（GodotGrass 滚动噪声思想的免采样版）：
// 平滑连续、无纹理依赖，[-1,1]
float n2(vec2 p) {
	return sin(p.x * 1.7 + sin(p.y * 0.8)) * 0.5
			+ sin(p.y * 2.3 + sin(p.x * 1.1)) * 0.5;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (UV2.x > 0.0) {
		float ph = UV2.y * 6.2831853;
		// 噪声风场（对马岛 GDC/GodotGrass：滚动噪声出风向风强）：
		// 大涡慢滚（阵风起伏 0.55-1.45 倍）+ 高频湍流抖叶尖。
		// 匀速正弦的"机械钟摆感"由此破除——风有阵性
		float wind = n2(wpos.xz * 0.06
				- vec2(u_wind_time * 0.55, u_wind_time * 0.35));
		float gust = 0.55 + 0.9 * (0.5 + 0.5 * wind);
		// UV2.x 由网格器烘"沿叶位置×(0.6+0.4×实际叶高)"（叶底恒 0）：
		// 平方衰减下端点摆幅 ∝ 叶高²——高草（2-3 格）受风远大于矮草
		// 地毯（力臂语义）；主摆常数 0.075 补偿矮草权重降幅
		float wave = u_wind_time * 1.55 + wpos.x * 0.28 + wpos.z * 0.22;
		float main_sway = sin(wave + ph) * 0.075 * gust;
		float turb = n2(wpos.xz * 0.45
				+ vec2(u_wind_time * 1.4, -u_wind_time * 1.1));
		float flutter = (sin(u_wind_time * 6.1 + ph * 2.7
				+ wpos.z * 0.9) * 0.6 + turb * 0.4) * 0.016 * gust;
		float amt = (main_sway + flutter) * UV2.x * UV2.x;
		VERTEX.x += amt * 0.83;
		VERTEX.z += amt * 0.55;
		// 远距加宽（GG CAMERA_FACE 思想的廉价近似）：叶梢向相机
		// 方向外扩，2-42m 渐入——细叶在远处不消失、草场显满。
		// 高草 UV2.x 可达 ~1.9，clamp 1.2 防加宽过度
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - wpos;
		float dist = length(to_cam);
		float far = clamp((dist - 2.0) / 40.0, 0.0, 1.0);
		float widen = far * 0.38 * 0.35 * min(UV2.x, 1.2);
		VERTEX.xz += normalize(vec2(to_cam.x, to_cam.z) + 1e-5) * widen;
	}
}

void fragment() {
	if (distance(INV_VIEW_MATRIX[3].xyz, sspr_mirror_cam_pos) < 0.01
			&& wpos.y < sspr_clip_y) {
		discard;
	}
	vec4 tex = texture(atlas, UV);
	if (cutout_mode && tex.a < 0.5) {
		discard;
	}
	// 顶点色双通道（见 atlas_tiling.gdshader 同款注释）：天光→ALBEDO
	// 受场景光；方块光→EMISSION 自发光（MC fullbright 语义）
	ALBEDO = tex.rgb * vec3(COLOR.a * u_day);
	EMISSION = tex.rgb * COLOR.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
