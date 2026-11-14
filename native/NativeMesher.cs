using Godot;
using System;
using System.Collections.Generic;

namespace VoxelTerrain;

/// <summary>
/// 网格管线的 C# 原生实现（§14 决策落地）。
/// 本构建的 C# API 不含 Packed*Array 类型，输入输出经 Variant 互转：
/// GDScript 侧的 PackedInt32Array / PackedByteArray 以 Variant 参数传入，
/// 内部转为 int[] / byte[]；输出数组用 Variant.CreateFrom 构造返回。
/// </summary>
public partial class NativeMesher : RefCounted
{
    private static readonly Vector3[][] FaceCorners =
    {
        new[] { new Vector3(1, 0, 1), new Vector3(1, 0, 0), new Vector3(1, 1, 0), new Vector3(1, 1, 1) },
        new[] { new Vector3(0, 0, 0), new Vector3(0, 0, 1), new Vector3(0, 1, 1), new Vector3(0, 1, 0) },
        new[] { new Vector3(0, 1, 0), new Vector3(0, 1, 1), new Vector3(1, 1, 1), new Vector3(1, 1, 0) },
        new[] { new Vector3(0, 0, 0), new Vector3(1, 0, 0), new Vector3(1, 0, 1), new Vector3(0, 0, 1) },
        new[] { new Vector3(0, 0, 1), new Vector3(1, 0, 1), new Vector3(1, 1, 1), new Vector3(0, 1, 1) },
        new[] { new Vector3(1, 0, 0), new Vector3(0, 0, 0), new Vector3(0, 1, 0), new Vector3(1, 1, 0) },
    };

    private static readonly Vector2[][] FaceCornerUvs =
    {
        new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) },
        new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) },
        new[] { new Vector2(0, 0), new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0) },
        new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) },
        new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) },
        new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) },
    };

    private static readonly int[] FaceNormalAxis = { 0, 0, 1, 1, 2, 2 };
    private static readonly int[] FaceNormalSign = { 1, -1, 1, -1, 1, -1 };
    private static readonly string[] FaceKind = { "side", "side", "top", "bottom", "side", "side" };

    // 面切向两轴（与 GDScript face_tan_axes 一致：normal 轴外两轴，
    // 顺序 [t1, t2]）——角点平滑光照采样用
    private static readonly int[][] FaceTanAxes =
    {
        new[] { 1, 2 }, new[] { 1, 2 }, new[] { 0, 2 },
        new[] { 0, 2 }, new[] { 0, 1 }, new[] { 0, 1 },
    };

    /// NativeTerrain 工厂：新 .cs 的 CSharpScript 在未 --import 的
    /// 环境下无法注册（.new 报 Nonexistent function），经由已注册的
    /// 本类转发构造（与 GDScript 新 class_name 全局类缓存同款坑）
    public NativeTerrain CreateTerrain(long worldSeed, int worldHeightBlocks,
        Variant blockIdsV)
        => new NativeTerrain(worldSeed, worldHeightBlocks, blockIdsV);

    // ---- 体素光照顶点色（GDScript ChunkMesher.vertex_light_color 逐位等价） ----

    private static int CornerComponent(Vector3 corner, int axis)
        => axis == 0 ? (int)corner.X : axis == 1 ? (int)corner.Y : (int)corner.Z;

    /// 角点平滑光照：面外层 2x2 四格平均（实心格光照 0 天然形成 AO）。
    /// 中间量全 double；深黑曲线 m^3 纯乘法（IEEE 确定，GD/C# 逐位一致）。
    /// 顶点色拆双通道语义（日夜循环地基，m^3 与 max 可交换故数学等价）：
    /// COLOR.rgb = 方块光暖色 × b^3，COLOR.a = 天光 s^3；着色器端
    /// max(COLOR.a × 日夜系数, COLOR.rgb)，夜晚方块光自动接管。
    private static Color VertexLightColor(
        byte[] lightPadded, int opIndex, int tan1Stride, int tan2Stride,
        int cornerT1, int cornerT2)
    {
        int o1 = cornerT1 == 0 ? -tan1Stride : 0;
        int o2 = cornerT2 == 0 ? -tan2Stride : 0;
        byte b0 = lightPadded[opIndex];
        byte b1 = lightPadded[opIndex + o1];
        byte b2 = lightPadded[opIndex + o2];
        byte b3 = lightPadded[opIndex + o1 + o2];
        int sky = (b0 >> 4) + (b1 >> 4) + (b2 >> 4) + (b3 >> 4);
        int blk = (b0 & 15) + (b1 & 15) + (b2 & 15) + (b3 & 15);
        double s = sky * 0.25 / 15.0;
        double b = blk * 0.25 / 15.0;
        double skyC = s * s * s;
        // BSL blocklightColor (255,212,160)：R+44%/B-44%（与 GD 侧逐位一致）
        double blkC = b * b * b;
        return new Color(
            (float)(blkC * 1.44),
            (float)blkC,
            (float)(blkC * 0.56),
            (float)skyC);
    }

    // ---- 面剔除 ----
    public Variant BuildNaive(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows,
        Variant renderKindV,
        Variant lightPaddedV, int grassDetail = 2)
    {
        int[] blockIds = blockIdsV.AsInt32Array();
        int[] neighborIds = neighborIdsV.AsInt32Array();
        byte[] neighborExists = (byte[])neighborExistsV;
        byte[] solid = (byte[])solidTableV;
        byte[] occl = (byte[])occludesTableV;
        int[] topTile = tileTopV.AsInt32Array();
        int[] sideTile = tileSideV.AsInt32Array();
        int[] bottomTile = tileBottomV.AsInt32Array();
        var states = statesV.AsGodotDictionary();
        bool hasStates = states != null && states.Count > 0;
        // dispatch 表（render_kind）：0=SKIP 1=OPAQUE 2=CUTOUT 3=CROSS
        byte[] renderKind = (byte[])renderKindV;

        int[] padded = BuildPaddedCache(chunkCoord, s, blockIds,
            neighborIds, neighborExists);

        List<Vector3> verts = new();
        List<Vector3> norms = new();
        List<Vector2> uvs = new();
        List<int> indices = new();
        List<int> cutIndices = new();
        List<Color> colors = new();
        List<int[]> plantCells = new();
        List<int[]> grassTopCells = new();
        int ps = s + 2;
        float invCols = 1f / atlasCols;
        float invRows = 1f / atlasRows;
        byte[] lightPadded = (byte[])lightPaddedV;
        int[] axisStride = { 1, ps, ps * ps };

        for (int z = 0; z < s; z++)
        for (int y = 0; y < s; y++)
        for (int x = 0; x < s; x++)
        {
            int pidx = (z + 1) * ps * ps + (y + 1) * ps + (x + 1);
            int blockId = padded[pidx];
            // dispatch 表分发（曾硬编码 AIR/WATER/BRANCH/LEAVES ID）：
            // cross = 十字面片（火把），循环后统一发射
            byte kind = renderKind[blockId];
            // 植物（kind=4）：循环后统一发射 X 十字面片（GD 同序）
            if (kind == 4)
            {
                plantCells.Add(new[] { x, y, z, pidx });
                continue;
            }
            // cross 桶（火把）由实体渲染器呈现，网格不出几何（用户实机
            // chunk cross 路径不可见——绕行）
            if (kind == 3)
                continue;
            if (kind == 0 || solid[blockId] == 0)
                continue;
            // 草方块顶露天空/植物/树冠枝占位（地毯全覆盖；B9d：树冠
            // 遮挡下曾不发叶=树下秃片被误读"渲染剔除扇形"）
            if (blockId == 1 && (padded[pidx + ps] == 0
                || renderKind[padded[pidx + ps]] == 4
                || padded[pidx + ps] == BranchId
                || padded[pidx + ps] == LeavesId))
                grassTopCells.Add(new[] { x, y, z, pidx });
            string axisState = hasStates
                ? GetAxisState(states, new Vector3I(x, y, z))
                : null;
            for (int f = 0; f < 6; f++)
            {
                int nAxis = FaceNormalAxis[f];
                int step = nAxis == 0 ? 1 : nAxis == 1 ? ps : ps * ps;
                if (occl[padded[pidx + (FaceNormalSign[f] > 0 ? step : -step)]] != 0)
                    continue;
                int tile = ResolveTile(blockId, axisState, f,
                    topTile, sideTile, bottomTile);
                // BetterGrassify 草坡融合 + 交界过渡（canFullyConnect =
                // relative(face).below()）：草暴露水平面，斜下格是草 →
                // 顶面 tile；否则切向邻面 blend → 对应侧草垂带变体
                //（GrassId=1；flip=切向正向走 u 减：+X/-Z 面；GD 同步）
                if (blockId == 1 && f != 2 && f != 3)
                {
                    int outward = FaceNormalSign[f] > 0 ? step : -step;
                    int diagBelow = pidx + outward - ps;
                    if (padded[diagBelow] == 1)
                        tile = topTile[1];
                    else
                    {
                        int tOff = f < 4 ? ps * ps : 1;  // ±X 面切向 z / ±Z 面 x
                        bool flip = f == 0 || f == 5;
                        int variant = 0;
                        for (int sgn = -1; sgn <= 1; sgn += 2)
                        {
                            int nb2 = pidx + sgn * tOff;
                            if (padded[nb2] == 1
                                && padded[nb2 + outward - ps] == 1)
                            {
                                if ((sgn > 0) == flip) variant |= 1;
                                else variant |= 2;
                            }
                        }
                        if (variant == 1) tile = GrassSideU0;
                        else if (variant == 2) tile = GrassSideU1;
                        else if (variant == 3) tile = GrassSideU01;
                    }
                }
                float rx = (tile % atlasCols) * invCols;
                float ry = (tile / atlasCols) * invRows;
                Vector3 normal = NormalFor(nAxis, FaceNormalSign[f]);
                int baze = verts.Count;
                // 面外层格的光照 padded 索引（角点采样基准）
                int opIndex = pidx + (FaceNormalSign[f] > 0 ? step : -step);
                int tan1 = axisStride[FaceTanAxes[f][0]];
                int tan2 = axisStride[FaceTanAxes[f][1]];
                for (int c = 0; c < 4; c++)
                {
                    Vector3 corner = FaceCorners[f][c];
                    verts.Add(new Vector3(x + corner.X, y + corner.Y, z + corner.Z));
                    norms.Add(normal);
                    Vector2 cu = FaceCornerUvs[f][c];
                    uvs.Add(new Vector2(rx + cu.X * invCols, ry + cu.Y * invRows));
                    colors.Add(VertexLightColor(lightPadded, opIndex,
                        tan1, tan2,
                        CornerComponent(corner, FaceTanAxes[f][0]),
                        CornerComponent(corner, FaceTanAxes[f][1])));
                }
                // cutout 桶（树叶，alpha 裁切材质，独立表面）——kind 查表
                var bucket = kind == 2 ? cutIndices : indices;
                bucket.Add(baze); bucket.Add(baze + 2); bucket.Add(baze + 1);
                bucket.Add(baze); bucket.Add(baze + 3); bucket.Add(baze + 2);
            }
        }
        // cross 桶循环后统一发射（与 GDScript 同序：植物 → 草叶；
        // 火把由实体渲染器呈现，网格不出几何——torch 发射已删）。
        // 草叶块级预算（审查 2-F2）：超预算块强制 detail 1（GD 同判
        // 定同常量——等价红线）
        if (grassTopCells.Count > GrassCellBudget && grassDetail > 1)
            grassDetail = 1;
        bool hasCross = plantCells.Count > 0 || grassTopCells.Count > 0;
        if (hasCross)
        {
            var cVerts = new List<Vector3>();
            var cNorms = new List<Vector3>();
            var cUvs = new List<Vector2>();
            var cUv2s = new List<Vector2>();
            var cColors = new List<Color>();
            var cIdx = new List<int>();
            int wxBase0 = chunkCoord.X * s;
            int wzBase0 = chunkCoord.Z * s;
            foreach (var cell in plantCells)
                if (padded[cell[3]] == TallGrassId)
                    // 高草株：×3.6 高叶簇+加宽（GD 同序同参——等价红线）
                    AppendGrassBlades(cVerts, cNorms, cUvs, cUv2s, cColors,
                        cIdx, cell[0], cell[1], cell[2], lightPadded,
                        cell[3], ps, invCols, invRows, atlasCols, atlasRows,
                        wxBase0 + cell[0], wzBase0 + cell[2],
                        TallNByDetail[grassDetail], TallPlantMult,
                        TallPlantY0, TallWMult, grassDetail);
                else
                    AppendPlantFaces(cVerts, cNorms, cUvs, cUv2s, cColors, cIdx,
                        cell[0], cell[1], cell[2], sideTile[padded[cell[3]]],
                        lightPadded, cell[3], ps, invCols, invRows, atlasCols,
                        atlasRows, wxBase0 + cell[0], wzBase0 + cell[2]);
            foreach (var cell in grassTopCells)
                AppendGrassBlades(cVerts, cNorms, cUvs, cUv2s, cColors, cIdx,
                    cell[0], cell[1], cell[2], lightPadded, cell[3], ps,
                    invCols, invRows, atlasCols, atlasRows,
                    wxBase0 + cell[0], wzBase0 + cell[2],
                    0, 1.0, 1.0, 1.0, grassDetail);
            return PackResult(verts, norms, uvs, null, indices, -1,
                cutIndices, colors, cVerts, cNorms, cUvs, cIdx, cColors,
                cUv2s);
        }
        return PackResult(verts, norms, uvs, null, indices, -1, cutIndices, colors);
    }

    // ---- 植被几何（植物 X 十字 + 草叶簇）已拆至 NativeMesher.Grass.cs
    //（审查修复第 4 批——partial class 纯移动）；体素光照初始化拆至
    // NativeMesher.Lighting.cs ----

    // ---- Greedy ----
    public Variant BuildGreedy(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows,
        Variant renderKindV,
        Variant lightPaddedV, int grassDetail = 2)
    {
        byte[] renderKind = (byte[])renderKindV;
        int[] blockIds = blockIdsV.AsInt32Array();
        int[] neighborIds = neighborIdsV.AsInt32Array();
        byte[] neighborExists = (byte[])neighborExistsV;
        byte[] solid = (byte[])solidTableV;
        byte[] occl = (byte[])occludesTableV;
        int[] topTile = tileTopV.AsInt32Array();
        int[] sideTile = tileSideV.AsInt32Array();
        int[] bottomTile = tileBottomV.AsInt32Array();
        var states = statesV.AsGodotDictionary();
        bool hasStates = states != null && states.Count > 0;

        int[] padded = BuildPaddedCache(chunkCoord, s, blockIds,
            neighborIds, neighborExists);

        List<Vector3> verts = new();
        List<Vector3> norms = new();
        List<Vector2> uvs = new();
        List<Vector2> uv2s = new();
        List<int> indices = new();
        List<Color> colors = new();
        int quads = 0;
        int ps = s + 2;
        float invCols = 1f / atlasCols;
        float invRows = 1f / atlasRows;
        int[] mask = new int[s * s];
        byte[] lightPadded = (byte[])lightPaddedV;
        int[] axisStride = { 1, ps, ps * ps };

        for (int axis = 0; axis < 3; axis++)
        {
            int uAxis = (axis + 1) % 3;
            int vAxis = (axis + 2) % 3;
            for (int boundary = 0; boundary <= s; boundary++)
            {
                bool aReal = boundary >= 1;
                bool bReal = boundary <= s - 1;
                bool any = false;
                for (int v = 0; v < s; v++)
                for (int u = 0; u < s; u++)
                {
                    int idxA = PaddedIndex(ps, axis, boundary, uAxis, vAxis, u, v);
                    int idxB = PaddedIndex(ps, axis, boundary + 1, uAxis, vAxis, u, v);
                    int a = padded[idxA];
                    int b = padded[idxB];
                    int encoded = 0;
                    // 水不进不透明贪心网格（独立半透明表面 BuildWater——
                    // 与 GDScript 贪心同判断；solid 表对水为 1 拦不住）
                    if (a == WaterId || b == WaterId)
                    {
                        mask[u + v * s] = 0;
                        continue;
                    }
                    // branchId：动态树占位不作发射方（区块无枝几何）；
                    // 作遮挡方时由 occl 表承担（占位 = 0 透明，不挡邻居面）
                    if (aReal && renderKind[a] != 0 && solid[a] != 0 && occl[b] == 0
                        && renderKind[a] != 4)
                    {
                        Vector3I local = ComposeLocal(axis, boundary - 1, uAxis, u, vAxis, v);
                        encoded = FaceTile(a, hasStates
                                ? GetAxisState(states, local) : null, axis, true,
                                topTile, sideTile, bottomTile) + 1;
                    }
                    else if (bReal && renderKind[b] != 0 && solid[b] != 0 && occl[a] == 0
                        && renderKind[b] != 4)
                    {
                        Vector3I local = ComposeLocal(axis, boundary, uAxis, u, vAxis, v);
                        encoded = -(FaceTile(b, hasStates
                            ? GetAxisState(states, local) : null, axis, false,
                            topTile, sideTile, bottomTile) + 1);
                    }
                    // BetterGrassify 草坡融合 + 交界过渡变体（GD 同步）：
                    // 斜下格草 → 顶面 tile；否则切向邻面 blend → 垂带变体
                    //（flip：positive 面 axis0/axis2 = true/false，negative 反之）
                    if (axis != 1 && encoded != 0)
                    {
                        int owner = encoded > 0 ? a : b;
                        if (owner == 1)
                        {
                            int sign = encoded > 0 ? 1 : -1;
                            int nbIdx = encoded > 0 ? idxB : idxA;
                            if (padded[nbIdx - ps] == 1)
                            {
                                encoded = sign * (topTile[1] + 1);
                            }
                            else
                            {
                                int ownerIdx = encoded > 0 ? idxA : idxB;
                                int outOff = encoded > 0
                                    ? axisStride[axis] : -axisStride[axis];
                                int tStride = axis == 0 ? ps * ps : 1;
                                bool flip = (encoded > 0) == (axis == 0);
                                int variant = 0;
                                for (int sgn = -1; sgn <= 1; sgn += 2)
                                {
                                    int nb2 = ownerIdx + sgn * tStride;
                                    if (padded[nb2] == 1
                                        && padded[nb2 + outOff - ps] == 1)
                                    {
                                        if ((sgn > 0) == flip) variant |= 1;
                                        else variant |= 2;
                                    }
                                }
                                if (variant == 1)
                                    encoded = sign * (GrassSideU0 + 1);
                                else if (variant == 2)
                                    encoded = sign * (GrassSideU1 + 1);
                                else if (variant == 3)
                                    encoded = sign * (GrassSideU01 + 1);
                            }
                        }
                    }
                    mask[u + v * s] = encoded;
                    if (encoded != 0) any = true;
                }
                if (!any) continue;

                for (int v0 = 0; v0 < s; v0++)
                for (int u0 = 0; u0 < s; )
                {
                    int m = mask[u0 + v0 * s];
                    if (m == 0) { u0++; continue; }
                    int u1 = u0 + 1;
                    while (u1 < s && mask[u1 + v0 * s] == m) u1++;
                    int v1 = v0 + 1;
                    while (v1 < s)
                    {
                        bool row = true;
                        for (int u = u0; u < u1; u++)
                            if (mask[u + v1 * s] != m) { row = false; break; }
                        if (!row) break;
                        v1++;
                    }
                    for (int vv = v0; vv < v1; vv++)
                    for (int uu = u0; uu < u1; uu++)
                        mask[uu + vv * s] = 0;

                    bool positive = m > 0;
                    int tile = (positive ? m : -m) - 1;
                    quads++;
                    Vector3 normal = NormalFor(axis, positive ? 1 : -1);
                    float rx = (tile % atlasCols) * invCols;
                    float ry = (tile / atlasCols) * invRows;
                    (int pu, int pv)[] corners = positive
                        ? new[] { (u0, v0), (u1, v0), (u1, v1), (u0, v1) }
                        : new[] { (u0, v0), (u0, v1), (u1, v1), (u1, v0) };
                    int baze = verts.Count;
                    // 面外层：positive（a 的 +axis 面）= boundary+1；
                    // negative（b 的 -axis 面）= boundary（GDScript 同规则）
                    int layer = positive ? boundary + 1 : boundary;
                    int strideU = axisStride[uAxis];
                    int strideV = axisStride[vAxis];
                    int opBase = layer * axisStride[axis] + strideU + strideV;
                    foreach (var (pu, pv) in corners)
                    {
                        verts.Add(ComposePosition(axis, boundary, uAxis, pu, vAxis, pv));
                        norms.Add(normal);
                        uv2s.Add(new Vector2(rx, ry));
                        colors.Add(VertexLightColor(lightPadded,
                            opBase + pu * strideU + pv * strideV,
                            strideU, strideV,
                            pu == u0 ? 0 : 1, pv == v0 ? 0 : 1));
                        if (axis == 1)
                            uvs.Add(new Vector2(pu - u0, pv - v0));
                        else if (axis == 0)
                            uvs.Add(new Vector2(pv - v0, u1 - pu));
                        else
                            uvs.Add(new Vector2(pu - u0, v1 - pv));
                    }
                    indices.Add(baze); indices.Add(baze + 2); indices.Add(baze + 1);
                    indices.Add(baze); indices.Add(baze + 3); indices.Add(baze + 2);
                    u0 = u1;
                }
            }
        }
        // cross 桶（火把）走实体渲染（TorchRenderer），网格不出几何。
        // 植物+草顶密叶（与 GDScript 贪心同序：掩码排除后循环补发）
        {
            var cVerts = new List<Vector3>();
            var cNorms = new List<Vector3>();
            var cUvs = new List<Vector2>();
            var cUv2s = new List<Vector2>();
            var cColors = new List<Color>();
            var cIdx = new List<int>();
            int ps2 = s + 2;
            for (int z = 0; z < s; z++)
            for (int y = 0; y < s; y++)
            for (int x = 0; x < s; x++)
            {
                int pidx = (z + 1) * ps2 * ps2 + (y + 1) * ps2 + (x + 1);
                int bid = padded[pidx];
                if (renderKind[bid] == 4)
                    if (bid == TallGrassId)
                        // 高草株 ×3.6 叶簇+加宽（与 GD 贪心/面剔除同源）
                        AppendGrassBlades(cVerts, cNorms, cUvs, cUv2s, cColors,
                            cIdx, x, y, z, lightPadded, pidx, ps2,
                            invCols, invRows, atlasCols, atlasRows,
                            chunkCoord.X * s + x, chunkCoord.Z * s + z,
                            TallNByDetail[grassDetail], TallPlantMult,
                            TallPlantY0, TallWMult, grassDetail);
                    else
                        AppendPlantFaces(cVerts, cNorms, cUvs, cUv2s, cColors, cIdx,
                            x, y, z, sideTile[bid], lightPadded, pidx, ps2,
                            invCols, invRows, atlasCols, atlasRows,
                            chunkCoord.X * s + x, chunkCoord.Z * s + z);
                else if (bid == 1 && (padded[pidx + ps2] == 0
                    || renderKind[padded[pidx + ps2]] == 4
                    || padded[pidx + ps2] == BranchId
                    || padded[pidx + ps2] == LeavesId))
                    AppendGrassBlades(cVerts, cNorms, cUvs, cUv2s, cColors, cIdx,
                        x, y, z, lightPadded, pidx, ps2,
                        invCols, invRows, atlasCols, atlasRows,
                        chunkCoord.X * s + x, chunkCoord.Z * s + z,
                        0, 1.0, 1.0, 1.0, grassDetail);
            }
            if (cIdx.Count > 0)
                return PackResult(verts, norms, uvs, uv2s, indices, quads,
                    null, colors, cVerts, cNorms, cUvs, cIdx, cColors,
                    cUv2s);
        }
        return PackResult(verts, norms, uvs, uv2s, indices, quads, null, colors);
    }

    // ---- 共用内部 ----

    // padded 缓冲每线程复用（审查 2-F1：曾每任务 new 18³ int≈23KB
    // ×26 邻拆分≈426KB——LOH 分配是流式加载期托管垃圾主源）
    [ThreadStatic] static int[] _paddedCache;

    static int[] RentPadded(int size)
    {
        var cache = _paddedCache;
        if (cache == null || cache.Length != size)
        {
            cache = new int[size];
            _paddedCache = cache;
        }
        return cache;
    }

    private static int[] BuildPaddedCache(
        Vector3I chunkCoord, int s,
        int[] blockIds, int[] neighborIds, byte[] neighborExists)
    {
        int ps = s + 2;
        int[] padded = RentPadded(ps * ps * ps);
        // 外壳段偏移表（按本任务 s 算，布局与 GD _pack_neighbors
        // 同构——slot 13 段长 0 永不被读；审查二轮 A2 替代曾 27 整块
        // 扁平传输 442KB/任务）
        int[] shellOff = new int[27];
        {
            int w0 = 0;
            for (int slot = 0; slot < 27; slot++)
            {
                int sdx = slot % 3 - 1, sdy = slot / 3 % 3 - 1,
                    sdz = slot / 9 - 1;
                if (sdx == 0 && sdy == 0 && sdz == 0) continue;
                shellOff[slot] = w0;
                int freeAxes = (sdx == 0 ? 1 : 0) + (sdy == 0 ? 1 : 0)
                    + (sdz == 0 ? 1 : 0);
                w0 += freeAxes == 2 ? s * s : freeAxes == 1 ? s : 1;
            }
        }

        for (int z = 0; z < s; z++)
        for (int y = 0; y < s; y++)
        for (int x = 0; x < s; x++)
            padded[(z + 1) * ps * ps + (y + 1) * ps + (x + 1)] =
                blockIds[x + s * y + s * s * z];

        int worldBelow = chunkCoord.Y * s;
        for (int pz = 0; pz < ps; pz++)
        for (int py = 0; py < ps; py++)
        {
            bool interiorRow = pz >= 1 && pz <= s && py >= 1 && py <= s;
            for (int px = 0; px < ps; px++)
            {
                if (interiorRow && px >= 1 && px <= s)
                    continue;
                int a = px - 1, b = py - 1, c = pz - 1;
                int dx = 0, dy = 0, dz = 0;
                int la = a, lb = b, lc = c;
                if (la < 0) { dx = -1; la = s - 1; } else if (la >= s) { dx = 1; la = 0; }
                if (lb < 0) { dy = -1; lb = s - 1; } else if (lb >= s) { dy = 1; lb = 0; }
                if (lc < 0) { dz = -1; lc = s - 1; } else if (lc >= s) { dz = 1; lc = 0; }
                int slot = (dz + 1) * 9 + (dy + 1) * 3 + (dx + 1);
                int borderId = 0;
                if (neighborExists[slot] != 0)
                {
                    // 外壳布局读（审查二轮 A2）：段偏移按 slot 累计、
                    // 自由轴 stride 序 z→y→x（与 GD _pack_neighbors
                    // 的 z 内层展开对偶——等价红线）
                    int si = shellOff[slot], stride = 1;
                    if (dz == 0) { si += lc * stride; stride *= s; }
                    if (dy == 0) { si += lb * stride; stride *= s; }
                    if (dx == 0) { si += la * stride; stride *= s; }
                    borderId = neighborIds[si];
                }
                else if (worldBelow + b < 0)
                    borderId = 4;
                padded[px + py * ps + pz * ps * ps] = borderId;
            }
        }
        return padded;
    }

    private static int PaddedIndex(
        int ps, int axis, int axisPos, int uAxis, int vAxis, int u, int v)
    {
        int x = 0, y = 0, z = 0;
        SetByAxis(ref x, ref y, ref z, axis, axisPos);
        SetByAxis(ref x, ref y, ref z, uAxis, u + 1);
        SetByAxis(ref x, ref y, ref z, vAxis, v + 1);
        return x + ps * y + ps * ps * z;
    }

    private static void SetByAxis(ref int x, ref int y, ref int z, int axis, int value)
    {
        if (axis == 0) x = value;
        else if (axis == 1) y = value;
        else z = value;
    }

    private static Vector3I ComposeLocal(
        int axis, int axisVal, int uAxis, int uVal, int vAxis, int vVal)
    {
        int x = 0, y = 0, z = 0;
        SetByAxis(ref x, ref y, ref z, axis, axisVal);
        SetByAxis(ref x, ref y, ref z, uAxis, uVal);
        SetByAxis(ref x, ref y, ref z, vAxis, vVal);
        return new Vector3I(x, y, z);
    }

    private static Vector3 ComposePosition(
        int axis, float axisVal, int uAxis, float uVal, int vAxis, float vVal)
    {
        float x = 0f, y = 0f, z = 0f;
        if (axis == 0) x = axisVal; else if (axis == 1) y = axisVal; else z = axisVal;
        if (uAxis == 0) x = uVal; else if (uAxis == 1) y = uVal; else z = uVal;
        if (vAxis == 0) x = vVal; else if (vAxis == 1) y = vVal; else z = vVal;
        return new Vector3(x, y, z);
    }

    private static Vector3 NormalFor(int axis, int sign)
    {
        if (axis == 0) return new Vector3(sign, 0f, 0f);
        if (axis == 1) return new Vector3(0f, sign, 0f);
        return new Vector3(0f, 0f, sign);
    }

    // 墙挂法线（火把 attach 状态："x,y,z"；缺省零向量 = 落地）
    private static Vector3I GetAttachState(
        Godot.Collections.Dictionary states, Vector3I local)
    {
        if (!states.ContainsKey(local)) return Vector3I.Zero;
        var entry = states[local].AsGodotDictionary();
        if (entry == null || !entry.ContainsKey("attach")) return Vector3I.Zero;
        var parts = entry["attach"].AsString().Split(',');
        if (parts.Length != 3) return Vector3I.Zero;
        return new Vector3I(
            int.Parse(parts[0]), int.Parse(parts[1]), int.Parse(parts[2]));
    }

    private static string GetAxisState(Godot.Collections.Dictionary states, Vector3I local)
    {
        if (!states.ContainsKey(local)) return null;
        var entry = states[local].AsGodotDictionary();
        if (entry == null || !entry.ContainsKey("axis")) return null;
        return entry["axis"].AsString();
    }

    private static int ResolveTile(
        int blockId, string axisState, int faceIndex,
        int[] topTile, int[] sideTile, int[] bottomTile)
    {
        if (axisState != null && topTile[blockId] >= 0 && sideTile[blockId] >= 0)
        {
            int axis = AxisFromString(axisState);
            return FaceNormalAxis[faceIndex] == axis
                ? topTile[blockId]
                : sideTile[blockId];
        }
        return FaceKind[faceIndex] switch
        {
            "top" => topTile[blockId],
            "bottom" => bottomTile[blockId],
            _ => sideTile[blockId],
        };
    }

    private static int FaceTile(
        int blockId, string axisState, int faceAxis, bool positive,
        int[] topTile, int[] sideTile, int[] bottomTile)
    {
        if (axisState != null && topTile[blockId] >= 0 && sideTile[blockId] >= 0)
        {
            return AxisFromString(axisState) == faceAxis
                ? topTile[blockId]
                : sideTile[blockId];
        }
        if (faceAxis == 1)
            return positive ? topTile[blockId] : bottomTile[blockId];
        return sideTile[blockId];
    }

    private static int AxisFromString(string axis)
    {
        return axis == "x" ? 0 : axis == "z" ? 2 : 1;
    }

    // ---- 水通道（与 GDScript ChunkMesher.append_water_faces 逐字节等价；
    // 等价测试 tests/test_native_equivalence.gd 水世界用例保证） ----
    private const float WaterSurfaceDrop = 0.125f;

    private static float WaterSurfaceHeight(int level)
    {
        if (level <= 0) return 1f - WaterSurfaceDrop;
        if (level >= 8) return 1f;
        return (8f - level) * (1f - WaterSurfaceDrop) / 8f;
    }

    /// 角点 (cx,cz)（padded x/z 坐标基础）的水面高度：共享该角点的
    /// 2x2 四格（同层）中所有水格顶高的最大值。水格顶高：上方是水
    /// -> 满格 1.0；否则按级别 WaterSurfaceHeight（levels 缺省 = 源）。
    /// 非水格贡献 0。levels 键为世界逻辑格坐标（padded 坐标 - 1）。
    private static float CornerWaterHeight(
        int[] padded, int ps, int y, int cx, int cz,
        Dictionary<(int, int, int), int> levels, int ox, int oy, int oz)
    {
        int strideY = ps;
        int strideZ = ps * ps;
        int row = (y + 1) * strideY;
        float best = 0f;
        for (int gzOff = 0; gzOff < 2; gzOff++)
        {
            int zbase = (cz + gzOff) * strideZ;
            for (int gxOff = 0; gxOff < 2; gxOff++)
            {
                int gx = cx + gxOff;
                int p = zbase + row + gx;
                if (padded[p] != WaterId)
                    continue;
                float h = 1f;
                if (padded[p + strideY] != WaterId)
                {
                    int lvl = levels.GetValueOrDefault((ox + gx - 1, oy + y, oz + cz + gzOff - 1), 0);
                    h = WaterSurfaceHeight(lvl);
                }
                if (h > best) best = h;
            }
        }
        return best;
    }

    /// 角点岸距衰减：角点自身 2x2 四格（同层与 y+1 层共 2x2x2）中的
    /// 非空非水格数直接决定（任何紧邻固体 -> 强衰减）。
    private static float CornerShoreFade(int[] padded, int ps, int cx, int cy, int cz)
    {
        int strideY = ps;
        int strideZ = ps * ps;
        int solid = 0;
        for (int layer = 0; layer < 2; layer++)
        {
            int row0 = (cy + 1 + layer) * strideY;
            for (int gzOff = 0; gzOff < 2; gzOff++)
            {
                int zbase = (cz + gzOff) * strideZ + row0;
                for (int gxOff = 0; gxOff < 2; gxOff++)
                {
                    int nid = padded[zbase + cx + gxOff];
                    if (nid != AirId && nid != WaterId)
                        solid++;
                }
            }
        }
        // 与 GDScript 对齐的浮点语义：f64 运算后单次舍入 f32
        //（全程 f32 会在 1-0.85 这类值上差 1 ULP，等价测试逐位比对挂）
        double f = solid * 0.5;
        if (f < 0.0) f = 0.0;
        if (f > 0.85) f = 0.85;
        return (float)(1.0 - f);
    }

    private const int AirId = 0;
    private const int WaterId = 14; // 与 VoxelTypes.WATER_ID 一致（写死前已对 voxel_types.gd 核对）

    public Variant BuildWater(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant levelXV, Variant levelYV, Variant levelZV, Variant levelVV,
        int originX, int originY, int originZ)
    {
        int[] blockIds = blockIdsV.AsInt32Array();
        int[] neighborIds = neighborIdsV.AsInt32Array();
        byte[] neighborExists = (byte[])neighborExistsV;
        int[] levelX = levelXV.AsInt32Array();
        int[] levelY = levelYV.AsInt32Array();
        int[] levelZ = levelZV.AsInt32Array();
        int[] levelV = levelVV.AsInt32Array();
        var levels = new Dictionary<(int, int, int), int>(levelX.Length);
        for (int i = 0; i < levelX.Length; i++)
            levels[(levelX[i], levelY[i], levelZ[i])] = levelV[i];

        int[] padded = BuildPaddedCache(chunkCoord, s, blockIds,
            neighborIds, neighborExists);
        int ps = s + 2;
        int strideY = ps;
        int strideZ = ps * ps;
        // 面偏移与 FACES 序一致：0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z
        int[] neighborOffsets = { 1, -1, strideY, -strideY, strideZ, -strideZ };
        // 6 向直接邻区块是否存在（同序）。缺失=尚未加载：那里格子的
        // "空气"只是未知，不能据此给水柱出侧壁，否则加载边界（视距圈
        // 边缘 / 流式加载前沿）会立起一圈从水面直落海底的竖墙——用户
        // 实机截图里"等距竖板幕帘"的来源。与 GDScript
        // ChunkMesher.loaded_dirs 逐位等价（同一 27 元素快照）。
        int[] dirNeighborIndex = { 14, 12, 16, 10, 22, 4 };
        bool[] dirLoaded = new bool[6];
        if (neighborExists != null && neighborExists.Length >= 27)
            for (int f = 0; f < 6; f++)
                dirLoaded[f] = neighborExists[dirNeighborIndex[f]] != 0;

        List<Vector3> verts = new();
        List<Vector3> norms = new();
        List<int> indices = new();
        List<Color> colors = new();
        List<Vector3> sideVerts = new();
        List<Vector3> sideNorms = new();
        List<int> sideIndices = new();
        List<Color> sideColors = new();

        for (int z = 0; z < s; z++)
        for (int y = 0; y < s; y++)
        for (int x = 0; x < s; x++)
        {
            int pidx = (z + 1) * strideZ + (y + 1) * strideY + (x + 1);
            if (padded[pidx] != WaterId)
                continue;
            for (int f = 0; f < 6; f++)
            {
                if (padded[pidx + neighborOffsets[f]] != AirId)
                    continue;
                bool isSide = FaceNormalAxis[f] != 1;
                // 朝未加载邻区块的侧壁不出面（见 dirLoaded 注释）。
                if (isSide && !dirLoaded[f])
                    continue;
                Vector3 normal = NormalFor(FaceNormalAxis[f], FaceNormalSign[f]);
                Vector3[] corners = FaceCorners[f];
                int baze = isSide ? sideVerts.Count : verts.Count;
                for (int c = 0; c < 4; c++)
                {
                    Vector3 corner = corners[c];
                    float vy = corner.Y;
                    int cx = x + (int)corner.X;
                    int cz = z + (int)corner.Z;
                    if (corner.Y == 1f)
                        vy = CornerWaterHeight(padded, ps, y, cx, cz,
                            levels, originX, originY, originZ);
                    var v = new Vector3(x + corner.X, y + vy, z + corner.Z);
                    float fade = CornerShoreFade(padded, ps, cx, y, cz);
                    var fadeColor = new Color(fade, 0f, 0f);
                    if (isSide)
                    {
                        sideVerts.Add(v);
                        sideNorms.Add(normal);
                        sideColors.Add(fadeColor);
                    }
                    else
                    {
                        verts.Add(v);
                        norms.Add(normal);
                        colors.Add(fadeColor);
                    }
                }
                var bucket = isSide ? sideIndices : indices;
                bucket.Add(baze); bucket.Add(baze + 2); bucket.Add(baze + 1);
                bucket.Add(baze); bucket.Add(baze + 3); bucket.Add(baze + 2);
            }
        }

        var result = new Godot.Collections.Dictionary
        {
            ["water_vertices"] = Variant.CreateFrom(verts.ToArray()),
            ["water_normals"] = Variant.CreateFrom(norms.ToArray()),
            ["water_indices"] = Variant.CreateFrom(indices.ToArray()),
            ["water_colors"] = Variant.CreateFrom(colors.ToArray()),
            ["water_side_vertices"] = Variant.CreateFrom(sideVerts.ToArray()),
            ["water_side_normals"] = Variant.CreateFrom(sideNorms.ToArray()),
            ["water_side_indices"] = Variant.CreateFrom(sideIndices.ToArray()),
            ["water_side_colors"] = Variant.CreateFrom(sideColors.ToArray()),
        };
        return Variant.CreateFrom(result);
    }

    private static Variant PackResult(
        List<Vector3> verts, List<Vector3> norms, List<Vector2> uvs,
        List<Vector2> uv2s, List<int> indices, int quads,
        List<int> cutoutIndices, List<Color> colors = null,
        List<Vector3> crossVerts = null, List<Vector3> crossNorms = null,
        List<Vector2> crossUvs = null, List<int> crossIndices = null,
        List<Color> crossColors = null, List<Vector2> crossUv2s = null)
    {
        var result = new Godot.Collections.Dictionary
        {
            ["vertices"] = Variant.CreateFrom(verts.ToArray()),
            ["normals"] = Variant.CreateFrom(norms.ToArray()),
            ["uvs"] = Variant.CreateFrom(uvs.ToArray()),
            ["indices"] = Variant.CreateFrom(indices.ToArray()),
        };
        if (uv2s != null)
            result["uv2"] = Variant.CreateFrom(uv2s.ToArray());
        if (quads >= 0)
            result["quads"] = quads;
        if (cutoutIndices != null)
            result["cutout_indices"] = Variant.CreateFrom(cutoutIndices.ToArray());
        if (colors != null)
            result["colors"] = Variant.CreateFrom(colors.ToArray());
        // cross 桶（火把等十字面片；独立数组/表面，不进碰撞）
        if (crossIndices != null && crossIndices.Count > 0)
        {
            result["cross_vertices"] = Variant.CreateFrom(crossVerts.ToArray());
            result["cross_normals"] = Variant.CreateFrom(crossNorms.ToArray());
            result["cross_uvs"] = Variant.CreateFrom(crossUvs.ToArray());
            result["cross_colors"] = Variant.CreateFrom(crossColors.ToArray());
            if (crossUv2s != null && crossUv2s.Count == crossVerts.Count)
                result["cross_uv2s"] = Variant.CreateFrom(crossUv2s.ToArray());
            result["cross_indices"] = Variant.CreateFrom(crossIndices.ToArray());
        }
        return Variant.CreateFrom(result);
    }
}
