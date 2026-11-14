using Godot;
using System;
using System.Collections.Generic;

namespace VoxelTerrain;

// 植被几何（植物 X 十字 + 草叶簇；常量/hash 盐与 GD ChunkMesher 同步
// ——等价红线）：自 NativeMesher.cs 拆出（审查修复第 4 批——纯移动，
// 零逻辑改动）。
public partial class NativeMesher
{
    // ---- 植物（plant 桶；与 GDScript ChunkMesher.append_plant_faces /
    // append_grass_blades 逐位一致——等价红线。常量/hash 盐同 GD） ----
    const float PlantInset = 0.15f;
    // GG 观感：细叶密植+区域草浪+簇姿态（常量与 GD 逐位同步）
    // B7 上调：整体加高+叶内高低差拉大+高草 ×3.6 超玩家
    const float BladeHalfW = 0.04f;      // GG BAKED_BASE_WIDTH
    // w 链全程 double 的镜像常量（GD 0.04/0.35 无 f32 截断；直接用
    // float 常量参与 double 乘会带 0.04f≠0.04 的 ULP 差——B7b 对拍坑）
    const double BladeHalfWd = 0.04;
    // 叶身曲线 4 关键（t 沿叶位置 / W 宽度比例；GD CURVE_T/CURVE_W 同）；
    // 中/远距降 2 关键直线锥叶（远观无折角感知，性能 B9——GD 同步）
    static readonly double[] CurveT = { 0.0, 0.30, 0.62, 1.0 };
    static readonly double[] CurveW = { 1.0, 0.90, 0.72, 0.35 };
    static readonly double[] CurveT2 = { 0.0, 1.0 };
    static readonly double[] CurveW2 = { 1.0, 0.35 };
    const double BladeHBase = 0.75;      // GG 默认 0.5075 → B7
    const double BladeHPer = 0.30;       // 叶内 0.80-1.10（默认 0.88+0.13）
    const float BladeLean = 0.16f;
    // 高草株：×3.6 叶簇（GG TALL_PLANT_HEIGHT_MULTIPLIER 3.0 → B7）
    const double TallPlantMult = 3.6;
    // 高草株片数按距离分级（GD TALL_N_BY_DETAIL 同步）
    static readonly int[] TallNByDetail = { 10, 14, 18 };
    const double TallWMult = 1.35;       // 高草叶整体加宽（double——
                                          // GD 侧无 f32 截断，ULP 对齐）
    const double TallPlantY0 = 0.02;
    const int TallGrassId = 19;          // VoxelTypes.TALL_GRASS_ID
    const int BranchId = 15;             // VoxelTypes.BRANCH_ID（树占位）
    const int LeavesId = 16;             // VoxelTypes.LEAVES_ID
    // GG NOISE_WORLD_TILE_BLOCKS=32（大区草浪；6 格太碎）
    const int SwellCell = 32;
    const long SwellSalt = 951;
    const int ClusterCell = 3;
    const long ClusterSalt = 961;
    const long BladeSaltPh = 971;
    const long PlantSaltPh = 981;
    const long BladeSaltN = 911;
    const long BladeSaltOx = 912;
    const long BladeSaltOz = 921;
    const long BladeSaltH = 931;
    const long BladeSaltD = 941;
    // grass_blade 的 TILES 序号（native_mesh_bridge.TILE_NAMES 同序）
    const int BladeTileIndex = 18;
    // 草侧面过渡变体序号（TILE_NAMES 同序；GD 侧 tile_grid 同名同号）
    const int GrassSideU0 = 22;
    const int GrassSideU1 = 23;
    const int GrassSideU01 = 24;

    static void AppendPlantFaces(List<Vector3> verts, List<Vector3> norms,
        List<Vector2> uvs, List<Vector2> uv2s, List<Color> colors, List<int> idx,
        int x, int y, int z, int tileIdx,
        byte[] lightPadded, int pidx, int ps,
        float invCols, float invRows, int atlasCols, int atlasRows,
        int wx, int wz)
    {
        float ox = (tileIdx % atlasCols) * invCols;
        float oy = (tileIdx / atlasCols) * invRows;
        var light = VertexLightColor(lightPadded, pidx, 1, 1, 1, 1);
        float i0 = PlantInset, i1 = 1f - PlantInset;
        // 与 GD quads 表同序：先 (i0,i0)-(i1,i1) 再 (i0,i1)-(i1,i0)。
        // 两对角 quad 各单片、单绕序单对角线（cross 材质 cull_disabled
        // 双面——B9；曾双绕序双对角线=单面材质时代设计）+ UV2 风摆
        double pph = NativeTerrain.Hash01(wx, wz, PlantSaltPh);
        var quads = new[] {
            new[] { new Vector3(x + i0, y, z + i0), new Vector3(x + i1, y, z + i1) },
            new[] { new Vector3(x + i0, y, z + i1), new Vector3(x + i1, y, z + i0) },
        };
        foreach (var q in quads)
        {
            int baze = verts.Count;
            verts.Add(q[0]);
            verts.Add(q[1]);
            verts.Add(q[0] + new Vector3(0, 1, 0));
            verts.Add(q[1] + new Vector3(0, 1, 0));
            for (int k = 0; k < 4; k++)
            {
                norms.Add(Vector3.Up);
                colors.Add(light);
            }
            uvs.Add(new Vector2(ox, oy + invRows));
            uvs.Add(new Vector2(ox + invCols, oy + invRows));
            uvs.Add(new Vector2(ox, oy));
            uvs.Add(new Vector2(ox + invCols, oy));
            uv2s.Add(new Vector2(0f, (float)pph));
            uv2s.Add(new Vector2(0f, (float)pph));
            uv2s.Add(new Vector2(1f, (float)pph));
            uv2s.Add(new Vector2(1f, (float)pph));
            // 单绕序单对角线（cross 材质 cull_disabled——性能 B9；
            // 双对角线写法曾留三角洞——B8b 修复；GD 同步）
            idx.Add(baze); idx.Add(baze + 2); idx.Add(baze + 1);
            idx.Add(baze + 1); idx.Add(baze + 2); idx.Add(baze + 3);
        }
    }

    static void AppendGrassBlades(List<Vector3> verts, List<Vector3> norms,
        List<Vector2> uvs, List<Vector2> uv2s, List<Color> colors, List<int> idx,
        int x, int y, int z, byte[] lightPadded, int pidx, int ps,
        float invCols, float invRows, int atlasCols, int atlasRows,
        int wx, int wz, int nOverride = 0, double hMult = 1.0,
        double y0Off = 1.0, double wMult = 1.0, int detail = 2)
    {
        float ox = (BladeTileIndex % atlasCols) * invCols;
        float oy = (BladeTileIndex / atlasCols) * invRows;
        // 光照取草块上方格（+Y = ps——与 GD 同源）
        var light = VertexLightColor(lightPadded, pidx + ps, 1, 1, 1, 1);
        // GDScript float = 64 位 double：hash 判定与坐标运算全程
        // double、构造 Vector3 时一次转型
        // 区域草浪：SWELL_CELL 粗格四角 hash 双线性（大片共享高度）
        double gx = wx / (double)SwellCell;
        double gz = wz / (double)SwellCell;
        int sx = (int)System.Math.Floor(gx);
        int sz = (int)System.Math.Floor(gz);
        double fx = gx - sx;
        double fz = gz - sz;
        double h00 = NativeTerrain.Hash01(sx, sz, SwellSalt);
        double h10 = NativeTerrain.Hash01(sx + 1, sz, SwellSalt);
        double h01 = NativeTerrain.Hash01(sx, sz + 1, SwellSalt);
        double h11 = NativeTerrain.Hash01(sx + 1, sz + 1, SwellSalt);
        // GG HEIGHT_NOISE：contrast 1.35 → 0.1-1.28，fraction 0.59 混合
        double hn = System.Math.Pow(
            Lerp(Lerp(h00, h10, fx), Lerp(h01, h11, fx), fz), 1.35);
        double swell = 1.0 + 0.59 * (Lerp(0.1, 1.28, hn) - 1.0);
        // 叶向基准角（每格一个，格间全随机；GD 同步——格内成束近看
        // 自然，任何视角每格都有近正对叶面）
        double cellAngle = System.Math.PI * 2.0 * NativeTerrain.Hash01(
            wx, wz, ClusterSalt);
        double rN = NativeTerrain.Hash01(wx, wz, BladeSaltN);
        // 密度三档 56/64/72，中心=GG DEFAULT_BLADES_PER_BLOCK 64
        // 距离分级（性能 B9）：中 48/远 32（GD 同步）
        int n = nOverride > 0 ? nOverride
            : detail >= 2
                ? (rN < 0.40 ? 56 : (rN < 0.80 ? 64 : 72))
                : (detail == 1 ? 48 : 32);
        for (int i = 0; i < n; i++)
        {
            double rOx = NativeTerrain.Hash01(wx * 4 + i, wz * 3 - i,
                BladeSaltOx + i);
            double rOz = NativeTerrain.Hash01(wx * 7 - i, wz * 5 + i,
                BladeSaltOz + i);
            double rH = NativeTerrain.Hash01(wx * 2 + i, wz * 9 + i,
                BladeSaltH + i);
            double rD = NativeTerrain.Hash01(wx * 6 + i, wz + i,
                BladeSaltD + i);
            double ph = NativeTerrain.Hash01(wx * 13 + i, wz * 17 - i,
                BladeSaltPh + i);
            // 贴边撒布（-0.04~1.04）：叶身跨格线互搭，消除格间断层
            double cx = x - 0.04 + 1.08 * rOx;
            double cz = z - 0.04 + 1.08 * rOz;
            // 叶长 = 基准 ×（高草株 ×3.6）× 区域草浪 × 叶内变化（0.80-1.10）
            double h = System.Math.Max(
                BladeHBase * hMult * swell * (0.80 + BladeHPer * rH), 0.02);
            // 叶朝向 = 格基准角 + 叶内 ±60° 扰动（GD 同步——同格
            // 多样，侧对方向也有大量近正对叶面）
            double ang = cellAngle + (rD - 0.5) * 2.1;
            var diag = new Vector2((float)System.Math.Cos(ang),
                (float)System.Math.Sin(ang));
            // 叶宽随机 0.75-1.25 ×（高草加宽）；w 链 double 常量——GD 同步
            double w = BladeHalfWd * (0.75 + 0.5 * rH) * wMult;
            var lean = diag * BladeLean;
            // 叶身曲线（GodotGrass/对马岛 GDC）：4 关键 8 顶点，水平偏移
            // ∝ t²（悬臂抛物线）+宽度沿 t 平滑收窄；3 关键 2 段折角生硬
            //（用户反馈"弯折的有些生硬"——GD 同步）
            int baze = verts.Count;
            double swayW = 0.6 + 0.4 * h;
            int ckeys = detail >= 2 ? 4 : 2;
            double[] curveT = ckeys == 4 ? CurveT : CurveT2;
            double[] curveW = ckeys == 4 ? CurveW : CurveW2;
            // 十字双面（用户"加厚度"）：侧对一面必正对另一面（等效厚
            // 度）。**性能 B10：十字只在近距**（detail<2 单面——GD 同
            // 步；外圈方向多样性由格级叶向保证）
            int faces = detail >= 2 ? 2 : 1;
            var perp = new Vector2(-diag.Y, diag.X);
            for (int ci = 0; ci < ckeys; ci++)
            {
                double t = curveT[ci];
                var halfA = diag * (float)(w * curveW[ci]);
                var halfB = perp * (float)(w * curveW[ci]);
                double t2 = t * t;
                double xoff = lean.X * t2;
                double zoff = lean.Y * t2;
                double hy = y + y0Off + h * t;
                verts.Add(new Vector3(
                    (float)(cx - halfA.X + xoff), (float)hy,
                    (float)(cz - halfA.Y + zoff)));
                verts.Add(new Vector3(
                    (float)(cx + halfA.X + xoff), (float)hy,
                    (float)(cz + halfA.Y + zoff)));
                if (faces == 2)
                {
                    verts.Add(new Vector3(
                        (float)(cx - halfB.X + xoff), (float)hy,
                        (float)(cz - halfB.Y + zoff)));
                    verts.Add(new Vector3(
                        (float)(cx + halfB.X + xoff), (float)hy,
                        (float)(cz + halfB.Y + zoff)));
                }
                for (int k = 0; k < faces * 2; k++)
                {
                    norms.Add(Vector3.Up);
                    colors.Add(light);
                }
                float vRow = (float)(oy + invRows * (1.0 - t));
                uvs.Add(new Vector2(ox, vRow));
                uvs.Add(new Vector2(ox + invCols, vRow));
                if (faces == 2)
                {
                    uvs.Add(new Vector2(ox, vRow));
                    uvs.Add(new Vector2(ox + invCols, vRow));
                }
                // UV2 = (风摆权重, 相位)：t ×(0.6+0.4h)——叶高烘进权重，
                // shader 平方衰减端点摆幅 ∝ h²（GD 同步）
                for (int k = 0; k < faces; k++)
                {
                    uv2s.Add(new Vector2((float)(swayW * t), (float)ph));
                    uv2s.Add(new Vector2((float)(swayW * t), (float)ph));
                }
            }
            // (ckeys-1) 段 × faces 面 quad 单绕序（cull_disabled——B9；
            // 关键 stride 2×faces；单对角线配对——B8b 教训；GD 同步）
            int stride = faces * 2;
            for (int s2 = 0; s2 < ckeys - 1; s2++)
            {
                int v0 = baze + s2 * stride;
                for (int f = 0; f < faces; f++)
                {
                    int q = v0 + f * 2;
                    idx.Add(q); idx.Add(q + stride); idx.Add(q + 1);
                    idx.Add(q + 1); idx.Add(q + stride); idx.Add(q + stride + 1);
                }
            }
        }
    }

    static double Lerp(double a, double b, double t) => a + (b - a) * t;
}
