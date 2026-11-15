// 雨丝着色器（天气批 2 观感第四轮）：自实现 FIXED_Y billboard——
// StandardMaterial3D 的 BILLBOARD_FIXED_Y 会忽略粒子 angle（引擎
// 强制 Y 对齐），雨丝永远竖直；本 shader 绕世界 Y 朝相机水平朝向
//（侧视可见+抬头仍竖直），并叠加两级倾斜：
//   u_tilt    全局风偏角（rad，风向/落速 atan——风向联动）
//   CUSTOM.x  per-粒子随机角（ParticleProcessMaterial.angle 写入，
//             -6°..18° 随机微扰防整齐平行）
// 雨丝倾斜方向=运动模糊拖影：顶端向上游（-风向）偏。
// 纹理条纹端部渐隐（_make_rain_streak_texture），unshaded 柔和混合。
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform sampler2D u_tex : hint_default_white, filter_linear;
uniform vec4 u_tint : source_color = vec4(0.78, 0.84, 0.94, 1.0);
uniform float u_tilt = 0.12;  // 全局风偏（rad）
uniform vec2 u_wind_dir = vec2(0.9, 0.45);  // 世界水平风向（归一）
// 遮蔽高度图（用户需求：方块/树叶下无雨）：R8 = (列表面高 -
// u_hm_base) / 80。粒子低于所在列高+0.9（半条雨丝+余量——顶端
// 触地整条消失）时顶点推到裁剪空间外
uniform sampler2D u_hm_tex : filter_linear;
uniform vec2 u_hm_center = vec2(0.0);  // 高度图世界 XZ 中心
uniform float u_hm_base = 0.0;  // R8 编码基准（世界 Y）
uniform float u_hm_half = 20.0;  // 半宽（米）

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	// 遮蔽：列高度采样（越界 clamp——发射盒就在覆盖域内）。
	// gdshader vertex 禁 return——退化分支只在 if 内设 POSITION
	vec2 huv = clamp((center.xz - u_hm_center) / (2.0 * u_hm_half)
			+ vec2(0.5), vec2(0.0), vec2(1.0));
	float surf = texture(u_hm_tex, huv).r * 80.0 + u_hm_base;
	if (center.y < surf + 0.9) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);  // 裁剪外：整面片消失
	} else {
		// 绕世界 Y 朝相机（只取水平分量——竖边保持世界竖直系）
		vec3 to_cam = CAMERA_POSITION_WORLD - center;
		to_cam.y = 0.0;
		to_cam = normalize(to_cam);
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
		// 倾斜：全局风偏 + per-粒子随机角（INSTANCE_CUSTOM.x 携带
		// ParticleProcessMaterial.angle，弧度）
		float tilt = u_tilt + INSTANCE_CUSTOM.x;
		vec3 up_tilted = normalize(vec3(
				-u_wind_dir.x * sin(tilt), cos(tilt),
				-u_wind_dir.y * sin(tilt)));
		vec3 world_pos = center + right * VERTEX.x + up_tilted * VERTEX.y;
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	}
}

void fragment() {
	vec4 t = texture(u_tex, UV);
	ALBEDO = u_tint.rgb;
	ALPHA = t.a * u_tint.a;
}
