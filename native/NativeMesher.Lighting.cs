using Godot;
using System;
using System.Collections.Generic;

namespace VoxelTerrain;

// 体素光照初始化（VoxelLightSystem.init_chunk_light 的 C# 等价——
// 列直射/方块光/BFS 播散/邻块边界播入）：自 NativeMesher.cs 拆出
//（审查修复第 4 批——纯移动，零逻辑改动）。
public partial class NativeMesher
{
    // ---- 体素光照初始化（GDScript VoxelLightSystem.init_chunk_light 等价）----

    /// 全量重算一个区块的光照（1 字节/格：高 4bit 天光、低 4bit 方块光）。
    /// 只算本块（列直射 + 光源 + 边界种子筛选 BFS + 6 面邻块光播入），
    /// 返回新 light 数组；跨块播出由 GDScript 主线程路径负责。
    /// neighborLights：6 面邻块 light（顺序 +x,-x,+y,-y,+z,-z），
    /// exists=0 的项忽略。opacity/emission 表由桥注入（数值 ID 索引）。
    /// skyAbove：本块正上方确为天空（世界顶层/垂直加载带顶）时才做
    /// 列直射 15 起算；否则从 0 起算（下界估计），由上方邻块边界播入
    /// 补齐——曾无条件 15 起算，深埋于区块顶层的洞穴格被灌满天光
    ///（合成探针实锤：上方邻块全实心仍得 sky=15）。
    public Variant InitChunkLight(
        int s,
        Variant blockIdsV, Variant opacityV, Variant emissionV,
        Variant neighborLightsV, Variant neighborExistsV,
        bool skyAbove)
    {
        int[] ids = blockIdsV.AsInt32Array();
        byte[] opacity = (byte[])opacityV;
        byte[] emission = (byte[])emissionV;
        var neighborLights = neighborLightsV.AsGodotArray();
        byte[] neighborExists = (byte[])neighborExistsV;
        const int MaxLevel = 15;
        byte[] light = new byte[s * s * s];

        // 1) 列直射天光：每列自顶向下，opacity 0 保持、逐层衰减、实心断链
        //    （仅 skyAbove；否则直射由上方邻块面播入 feedDown 规则延续）
        if (skyAbove)
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
}
