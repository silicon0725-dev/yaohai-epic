using Godot;
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

    // ---- 面剔除 ----
    public Variant BuildNaive(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows)
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
        int ps = s + 2;
        float invCols = 1f / atlasCols;
        float invRows = 1f / atlasRows;

        for (int z = 0; z < s; z++)
        for (int y = 0; y < s; y++)
        for (int x = 0; x < s; x++)
        {
            int pidx = (z + 1) * ps * ps + (y + 1) * ps + (x + 1);
            int blockId = padded[pidx];
            if (blockId == 0 || solid[blockId] == 0)
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
                for (int c = 0; c < 4; c++)
                {
                    Vector3 corner = FaceCorners[f][c];
                    verts.Add(new Vector3(x + corner.X, y + corner.Y, z + corner.Z));
                    norms.Add(normal);
                    Vector2 cu = FaceCornerUvs[f][c];
                    uvs.Add(new Vector2(rx + cu.X * invCols, ry + cu.Y * invRows));
                }
                indices.Add(baze); indices.Add(baze + 2); indices.Add(baze + 1);
                indices.Add(baze); indices.Add(baze + 3); indices.Add(baze + 2);
            }
        }
        return PackResult(verts, norms, uvs, null, indices, -1);
    }

    // ---- Greedy ----
    public Variant BuildGreedy(
        Vector3I chunkCoord, int s,
        Variant blockIdsV, Variant neighborIdsV, Variant neighborExistsV,
        Variant solidTableV, Variant occludesTableV,
        Variant tileTopV, Variant tileSideV, Variant tileBottomV,
        Variant statesV,
        int atlasCols, int atlasRows)
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
        int quads = 0;
        int ps = s + 2;
        float invCols = 1f / atlasCols;
        float invRows = 1f / atlasRows;
        int[] mask = new int[s * s];

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
                    if (aReal && solid[a] != 0 && occl[b] == 0)
                    {
                        Vector3I local = ComposeLocal(axis, boundary - 1, uAxis, u, vAxis, v);
                        encoded = FaceTile(a, hasStates
                                ? GetAxisState(states, local) : null, axis, true,
                                topTile, sideTile, bottomTile) + 1;
                    }
                    else if (bReal && solid[b] != 0 && occl[a] == 0)
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
                    foreach (var (pu, pv) in corners)
                    {
                        verts.Add(ComposePosition(axis, boundary, uAxis, pu, vAxis, pv));
                        norms.Add(normal);
                        uv2s.Add(new Vector2(rx, ry));
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
        return PackResult(verts, norms, uvs, uv2s, indices, quads);
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

    private static Variant PackResult(
        List<Vector3> verts, List<Vector3> norms, List<Vector2> uvs,
        List<Vector2> uv2s, List<int> indices, int quads)
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
        return Variant.CreateFrom(result);
    }
}
