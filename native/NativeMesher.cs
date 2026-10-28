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
    /// 中间量全 double；深黑曲线 m^3 纯乘法（IEEE 确定，GD/C# 逐位一致）；
    /// 方块光占优时色温偏暖。
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
        // 深黑洞穴曲线 m^3（纯乘法 IEEE 确定，与 GDScript 逐位一致；
        // m^1.5 观感太缓，洞内天光 10-12 区域不显暗）
        double m = Math.Max(s, b);
        double bright = m * m * m;
        // BSL blocklightColor (255,212,160)：R+44%/B-44%（与 GD 侧逐位一致）
        double warm = 0.0;
        if (b > s)
            warm = Math.Clamp((b - s) * 2.0, 0.0, 1.0);
        return new Color(
            (float)(bright * (1.0 + 0.44 * warm)),
            (float)bright,
            (float)(bright * (1.0 - 0.44 * warm)));
    }

    // ---- 面剔除 ----
    public Variant BuildNaive(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows,
        int branchId, int leavesId,
        Variant lightPaddedV)
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

        int[] padded = BuildPaddedCache(chunkCoord, s, blockIds,
            neighborIds, neighborExists);

        List<Vector3> verts = new();
        List<Vector3> norms = new();
        List<Vector2> uvs = new();
        List<int> indices = new();
        List<int> cutIndices = new();
        List<Color> colors = new();
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
            // branchId：动态树占位（渲染走树实体独立网格，不出区块几何）
            // waterId：水走独立半透明通道（BuildWater；solid 表对水为 1，
            // 不能靠表排除——GDScript 侧同为显式判断）
            if (blockId == 0 || blockId == branchId || blockId == WaterId
                || solid[blockId] == 0)
                continue;
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
                // leavesId：叶面走 cutout 桶（alpha 裁切材质，独立表面）
                var bucket = blockId == leavesId ? cutIndices : indices;
                bucket.Add(baze); bucket.Add(baze + 2); bucket.Add(baze + 1);
                bucket.Add(baze); bucket.Add(baze + 3); bucket.Add(baze + 2);
            }
        }
        return PackResult(verts, norms, uvs, null, indices, -1, cutIndices, colors);
    }

    // ---- Greedy ----
    public Variant BuildGreedy(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows,
        int branchId,
        Variant lightPaddedV)
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
                    if (aReal && a != branchId && solid[a] != 0 && occl[b] == 0)
                    {
                        Vector3I local = ComposeLocal(axis, boundary - 1, uAxis, u, vAxis, v);
                        encoded = FaceTile(a, hasStates
                                ? GetAxisState(states, local) : null, axis, true,
                                topTile, sideTile, bottomTile) + 1;
                    }
                    else if (bReal && b != branchId && solid[b] != 0 && occl[a] == 0)
                    {
                        Vector3I local = ComposeLocal(axis, boundary, uAxis, u, vAxis, v);
                        encoded = -(FaceTile(b, hasStates
                                ? GetAxisState(states, local) : null, axis, false,
                                topTile, sideTile, bottomTile) + 1);
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
        return PackResult(verts, norms, uvs, uv2s, indices, quads, null, colors);
    }

    // ---- 共用内部 ----

    private static int[] BuildPaddedCache(
        Vector3I chunkCoord, int s,
        int[] blockIds, int[] neighborIds, byte[] neighborExists)
    {
        int ps = s + 2;
        int volume = s * s * s;
        int[] padded = new int[ps * ps * ps];
        int[][] nb = new int[27][];
        for (int i = 0; i < 27; i++)
        {
            if (neighborExists[i] != 0)
            {
                int[] arr = new int[volume];
                System.Array.Copy(neighborIds, i * volume, arr, 0, volume);
                nb[i] = arr;
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
                if (nb[slot] != null)
                    borderId = nb[slot][la + s * lb + s * s * lc];
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

    // ---- 体素光照初始化（GDScript VoxelLightSystem.init_chunk_light 等价）----

    /// 全量重算一个区块的光照（1 字节/格：高 4bit 天光、低 4bit 方块光）。
    /// 只算本块（列直射 + 光源 + 边界种子筛选 BFS + 6 面邻块光播入），
    /// 返回新 light 数组；跨块播出由 GDScript 主线程路径负责。
    /// neighborLights：6 面邻块 light（顺序 +x,-x,+y,-y,+z,-z），
    /// exists=0 的项忽略。opacity/emission 表由桥注入（数值 ID 索引）。
    public Variant InitChunkLight(
        int s,
        Variant blockIdsV, Variant opacityV, Variant emissionV,
        Variant neighborLightsV, Variant neighborExistsV)
    {
        int[] ids = blockIdsV.AsInt32Array();
        byte[] opacity = (byte[])opacityV;
        byte[] emission = (byte[])emissionV;
        var neighborLights = neighborLightsV.AsGodotArray();
        byte[] neighborExists = (byte[])neighborExistsV;
        const int MaxLevel = 15;
        byte[] light = new byte[s * s * s];

        // 1) 列直射天光：每列自顶向下，opacity 0 保持、逐层衰减、实心断链
        for (int z = 0; z < s; z++)
        for (int x = 0; x < s; x++)
        {
            int level = MaxLevel;
            for (int y = s - 1; y >= 0; y--)
            {
                int i = x + s * (y + s * z);
                int op = opacity[ids[i]];
                if (op >= MaxLevel) break;
                if (op > 0) level = Math.Max(0, level - Math.Max(1, op));
                if (level <= 1) break;
                light[i] = (byte)((light[i] & 0x0F) | (level << 4));
            }
        }
        // 2) 方块光光源（本轮表全 0，框架就位）
        for (int i = 0; i < ids.Length; i++)
        {
            int em = emission[ids[i]];
            if (em > 0)
                light[i] = (byte)((light[i] & 0xF0) | em);
        }
        // 3) 种子筛选（光照不连续边界）+ 单块 BFS——天光通道
        List<int> skySeeds = new();
        for (int z = 0; z < s; z++)
        for (int y = 0; y < s; y++)
        for (int x = 0; x < s; x++)
        {
            int i = x + s * (y + s * z);
            int v = light[i] >> 4;
            if (v <= 1) continue;
            if (IsSkyBorder(ids, opacity, light, s, x, y, z, i, v))
                skySeeds.Add(i);
        }
        BfsSky(ids, opacity, light, s, skySeeds);
        // 方块光通道种子（发光格）
        List<int> blkSeeds = new();
        for (int i = 0; i < ids.Length; i++)
            if ((light[i] & 0x0F) > 1) blkSeeds.Add(i);
        BfsBlock(ids, opacity, light, s, blkSeeds);
        // 4) 6 面邻块边界光播入（邻亮我暗方向的输入；
        //    feed_down = 邻块在本块上方（axis == +y，即 k=2））
        for (int k = 0; k < 6; k++)
        {
            if (neighborExists[k] == 0) continue;
            byte[] nbLight = (byte[])neighborLights[k];
            bool feedDown = k == 2;
            int ax = k / 2 == 0 ? (k == 0 ? 1 : -1) : 0;
            int ay = k / 2 == 1 ? (k == 2 ? 1 : -1) : 0;
            int az = k / 2 == 2 ? (k == 4 ? 1 : -1) : 0;
            List<int> inSky = new();
            List<int> inBlk = new();
            for (int a = 0; a < s; a++)
            for (int b = 0; b < s; b++)
            {
                (int mx, int my, int mz) = FaceCell(s, ax, ay, az, a, b);
                int mi = mx + s * (my + s * mz);
                (int nx, int ny, int nz) = MirrorCell(s, ax, ay, az, mx, my, mz);
                int nbByte = nbLight[nx + s * (ny + s * nz)];
                int op = opacity[ids[mi]];
                if (op >= MaxLevel) continue;
                int nlSky = StepLevel(nbByte >> 4, op, feedDown, true);
                if (nlSky > (light[mi] >> 4))
                {
                    light[mi] = (byte)((light[mi] & 0x0F) | (nlSky << 4));
                    inSky.Add(mi);
                }
                int nlBlk = StepLevel(nbByte & 0x0F, op, feedDown, false);
                if (nlBlk > (light[mi] & 0x0F))
                {
                    light[mi] = (byte)((light[mi] & 0xF0) | nlBlk);
                    inBlk.Add(mi);
                }
            }
            if (inSky.Count > 0)
                BfsSky(ids, opacity, light, s, inSky);
            if (inBlk.Count > 0)
                BfsBlock(ids, opacity, light, s, inBlk);
        }
        return Variant.CreateFrom(light);
    }

    private static int StepLevel(int lv, int op, bool down, bool sky)
    {
        if (sky && down && lv == 15 && op == 0)
            return 15;
        return lv - Math.Max(1, op);
    }

    /// axis 正向端面格（axis 单位分量 ax/ay/az；切向参数 a/b）。
    private static (int, int, int) FaceCell(
        int s, int ax, int ay, int az, int a, int b)
    {
        if (ax != 0)
            return (ax > 0 ? s - 1 : 0, a, b);
        if (ay != 0)
            return (a, ay > 0 ? s - 1 : 0, b);
        return (a, b, az > 0 ? s - 1 : 0);
    }

    /// 我方面格映射到邻块内一格（axis 分量翻面，切向不变）。
    private static (int, int, int) MirrorCell(
        int s, int ax, int ay, int az, int x, int y, int z)
    {
        if (ax != 0)
            return (ax > 0 ? 0 : s - 1, y, z);
        if (ay != 0)
            return (x, ay > 0 ? 0 : s - 1, z);
        return (x, y, az > 0 ? 0 : s - 1);
    }

    /// 天光种子判定：任一邻格满足"我能把它提升"（值差 >= 2，或其为
    /// 半透明且 v - max(1,op) > 其现值）。
    private static bool IsSkyBorder(
        int[] ids, byte[] opacity, byte[] light, int s,
        int x, int y, int z, int i, int v)
    {
        int sy = s;
        int sz = s * s;
        if (x > 0 && SeedPairAt(ids, opacity, light, i - 1, v)) return true;
        if (x < s - 1 && SeedPairAt(ids, opacity, light, i + 1, v)) return true;
        if (y > 0 && SeedPairAt(ids, opacity, light, i - sy, v)) return true;
        if (y < s - 1 && SeedPairAt(ids, opacity, light, i + sy, v)) return true;
        if (z > 0 && SeedPairAt(ids, opacity, light, i - sz, v)) return true;
        if (z < s - 1 && SeedPairAt(ids, opacity, light, i + sz, v)) return true;
        return false;
    }

    private static bool SeedPairAt(
        int[] ids, byte[] opacity, byte[] light, int iNb, int v)
    {
        int nbV = light[iNb] >> 4;
        if (v - nbV >= 2) return true;
        int op = opacity[ids[iNb]];
        return op < 15 && v - Math.Max(1, op) > nbV;
    }

    /// 单块天光 BFS（线性索引队列，内联步进；不越本块）。
    private static void BfsSky(
        int[] ids, byte[] opacity, byte[] light, int s, List<int> queue)
    {
        int head = 0;
        while (head < queue.Count)
        {
            int i = queue[head];
            head++;
            int lv = light[i] >> 4;
            if (lv <= 1) continue;
            int x = i % s;
            int t = i / s;
            int y = t % s;
            int z = t / s;
            if (x + 1 < s) TrySky(ids, opacity, light, queue, i + 1, lv, false);
            if (x > 0) TrySky(ids, opacity, light, queue, i - 1, lv, false);
            if (y + 1 < s) TrySky(ids, opacity, light, queue, i + s, lv, false);
            if (y > 0) TrySky(ids, opacity, light, queue, i - s, lv, true);
            if (z + 1 < s) TrySky(ids, opacity, light, queue, i + s * s, lv, false);
            if (z > 0) TrySky(ids, opacity, light, queue, i - s * s, lv, false);
        }
    }

    private static void TrySky(
        int[] ids, byte[] opacity, byte[] light, List<int> queue,
        int ni, int lv, bool down)
    {
        int op = opacity[ids[ni]];
        if (op >= 15) return;
        int nl = lv - Math.Max(1, op);
        if (down && lv == 15 && op == 0)
            nl = 15;  // 天光垂直直射
        if (nl <= 1) return;
        int cur = light[ni] >> 4;
        if (cur >= nl) return;
        light[ni] = (byte)((light[ni] & 0x0F) | (nl << 4));
        queue.Add(ni);
    }

    /// 单块方块光 BFS。
    private static void BfsBlock(
        int[] ids, byte[] opacity, byte[] light, int s, List<int> queue)
    {
        int head = 0;
        while (head < queue.Count)
        {
            int i = queue[head];
            head++;
            int lv = light[i] & 0x0F;
            if (lv <= 1) continue;
            int x = i % s;
            int t = i / s;
            int y = t % s;
            int z = t / s;
            void Try(int ni)
            {
                int op = opacity[ids[ni]];
                if (op >= 15) return;
                int nl = lv - Math.Max(1, op);
                if (nl <= 1) return;
                int cur = light[ni] & 0x0F;
                if (cur >= nl) return;
                light[ni] = (byte)((light[ni] & 0xF0) | nl);
                queue.Add(ni);
            }
            if (x + 1 < s) Try(i + 1);
            if (x > 0) Try(i - 1);
            if (y + 1 < s) Try(i + s);
            if (y > 0) Try(i - s);
            if (z + 1 < s) Try(i + s * s);
            if (z > 0) Try(i - s * s);
        }
    }

    private static Variant PackResult(
        List<Vector3> verts, List<Vector3> norms, List<Vector2> uvs,
        List<Vector2> uv2s, List<int> indices, int quads,
        List<int> cutoutIndices, List<Color> colors = null)
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
        return Variant.CreateFrom(result);
    }
}
