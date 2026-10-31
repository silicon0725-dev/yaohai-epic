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

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
