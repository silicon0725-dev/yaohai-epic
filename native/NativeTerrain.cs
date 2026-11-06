using Godot;
using System;
using System.Collections.Generic;

namespace VoxelTerrain;

/// <summary>
/// 地形生成的 C# 原生实现（阶段：generate C# 化）。
/// 覆盖 TerrainGenerator.generate_chunk 的"列剖面 + 方块填充"主体；
/// 树重放留在 GDScript（依赖 hash([seed,x,z])/RandomNumberGenerator
/// 序列与树形态算法，等价风险长尾——与"树不迁 C#"决策自洽），
/// 本类额外输出每列 height/sandy/rocky 剖面数组供其免重复算噪声。
///
/// 等价红线（GDScript float = 64 位 double）：
/// - 计算链全程 double（噪声引擎返回 float 提升，后续运算必须 double）
/// - round() 复刻 GD 的 half-away-from-zero（C# Math.Round 是银行家舍入）
/// - smoothstep 手写标准公式（与 Godot 内建实现一致）
/// - 噪声对象按同参数构建（FastNoiseLite 引擎实现，跨语言同值）
/// </summary>
public partial class NativeTerrain : RefCounted
{
    private const int GeneratorVersion = 8;
    private const int DirtLayerDepth = 3;
    // v9 高度联动：海平面/沙线/铁矿带随世界高度派生（构造期算；
    // GD 侧 TerrainGenerator.sea_level_for 位同步——48 高=7 逐格一致，
    // 其余 H/8）
    private readonly int _seaLevel;
    private readonly int _sandMaxHeight;
    private readonly int _ironOreMaxY;
    private const int OreSurfaceMargin = 4;
    // v7 洞穴与矿脉（Minetest cavegen/mg_ore 算法移植）。
    // 阈值按归一化噪声实测分位标定（探针：W=0.88 → 隧道 ~3.5%、
    // 剖面中位 3 格可通行；煤 ~2.1%、铁 ~0.74%）——Minetest 的
    // 0.09/0.16/0.30 依赖其噪声 scale=3 的宽值域，FastNoiseLite
    // 归一输出下不可直接套用。
    private const double CaveWidth = 0.88;
    private const double CaveFreq = 1.0 / 48.0;
    private const int CaveOctaves = 2;
    private const double CheeseFreq = 1.0 / 64.0;
    private const int CheeseOctaves = 2;
    private const double CheeseThreshold = 0.58;
    private const int CheeseMinDepth = 8;
    private const double VeinFreq = 1.0 / 16.0;
    private const int VeinOctaves = 1;
    private const double VeinJitter = 0.04;
    private const double CoalVeinValue = 0.92;
    private const double IronVeinValue = 0.965;
    private const int KnotCount = 17;
    // v8 地形塑形（Epic-Terrain 配比，巨型档=其尺度 ÷2）
    private const double ContinentFreq = 1.0 / 4096.0;
    private const int ContinentOctaves = 6;
    private const double MountainMaskFreq = 1.0 / 2048.0;
    private const double RidgeFreq = 1.0 / 1024.0;
    private const int RidgeOctaves = 5;
    private const double MountainGain = 0.46;
    private const double ErodeFreq = 1.0 / 1024.0;
    private const double ErodeGain1 = 0.5;
    private const double ErodeGain2 = 0.3;
    private const double ErodeGain3 = 0.17;
    private const double ErodeGain4 = 0.08;
    private const double CoastRiseLo = 0.06;
    private const double CoastRiseHi = 0.11;
    private const double CoastFallLo = 0.24;
    private const double CoastFallHi = 0.34;
    private const double CoastErodeGain = 0.07;
    private const double InlandErodeGain = 0.03;
    private const double RiverFreq = 1.0 / 2048.0;
    private const int RiverOctaves = 4;
    private const double RiverModFreq = 1.0 / 1024.0;
    private const double RiverBand = 0.001;
    private const double RiverFrac = 0.085;
    private const double RiverBase = 0.4;
    private const double MountainGateLo = 0.30;
    private const double MountainGateHi = 0.60;
    private const double RockSurfaceFrac = 0.62;
    private const double TempLapse = 0.9;
    private const double DesertTemp = 0.30;
    private const double DesertDryness = -0.10;
    private const double DesertMaxFrac = 0.45;
    private const int TreeReach = 4;

    private static readonly double[] TargetHeightFrac =
    {
        0.030, 0.055, 0.075, 0.095, 0.115, 0.135, 0.155, 0.180,
        0.205, 0.235, 0.270, 0.315, 0.370, 0.445, 0.540, 0.680, 0.900,
    };

    // 块 ID 由桥从 VoxelTypes 常量传入（不硬编码——两轮迁移三次
    // 猜错 ID，教训：常量表必须单一来源）
    private readonly int _grassId;
    private readonly int _dirtId;
    private readonly int _stoneId;
    private readonly int _bedrockId;
    private readonly int _sandId;
    private readonly int _sandstoneId;
    private readonly int _coalOreId;
    private readonly int _ironOreId;
    private readonly int _waterId;

    private readonly FastNoiseLite _continental;
    private readonly FastNoiseLite _mountainMask;
    private readonly FastNoiseLite _ridge;
    private readonly FastNoiseLite _e0;
    private readonly FastNoiseLite _e1;
    private readonly FastNoiseLite _e2;
    private readonly FastNoiseLite _e3;
    private readonly FastNoiseLite _e4;
    private readonly FastNoiseLite _river1;
    private readonly FastNoiseLite _river2;
    private readonly FastNoiseLite _temp;
    private readonly FastNoiseLite _precip;
    private readonly FastNoiseLite _coal;
    private readonly FastNoiseLite _iron;
    // v7 洞穴与矿脉噪声（隧道双等值线 / 大洞厅 / 细脉双等值线）
    private readonly FastNoiseLite _cave1;
    private readonly FastNoiseLite _cave2;
    private readonly FastNoiseLite _cheese;
    private readonly FastNoiseLite _vein1;
    private readonly FastNoiseLite _vein2;
    private readonly double[] _sourceKnots;
    private readonly int _worldHeightBlocks;

    /// blockIds 顺序：[grass, dirt, stone, bedrock, sand, sandstone,
    /// coal_ore, iron_ore, water]（桥按 VoxelTypes 常量顺序打包）。
    public NativeTerrain(long worldSeed, int worldHeightBlocks,
        Variant blockIdsV)
    {
        int[] b = blockIdsV.AsInt32Array();
        _grassId = b[0];
        _dirtId = b[1];
        _stoneId = b[2];
        _bedrockId = b[3];
        _sandId = b[4];
        _sandstoneId = b[5];
        _coalOreId = b[6];
        _ironOreId = b[7];
        _waterId = b[8];
        _worldHeightBlocks = worldHeightBlocks;
        _seaLevel = worldHeightBlocks <= 48 ? 7 : worldHeightBlocks / 8;
        _sandMaxHeight = _seaLevel + 1;
        _ironOreMaxY = _seaLevel + 13;
        _continental = MakeFbm(worldSeed, ContinentFreq, ContinentOctaves);
        _mountainMask = MakeFbm(worldSeed + 101, MountainMaskFreq, 3);
        _temp = MakeFbm(worldSeed + 202, MountainMaskFreq, 3);
        _precip = MakeFbm(worldSeed + 303, MountainMaskFreq, 3);
        _ridge = new FastNoiseLite
        {
            Seed = (int)(worldSeed + 404),
            NoiseType = FastNoiseLite.NoiseTypeEnum.Simplex,
            Frequency = (float)RidgeFreq,
            FractalType = FastNoiseLite.FractalTypeEnum.Ridged,
            FractalOctaves = RidgeOctaves,
        };
        _e0 = MakeFbm(worldSeed + 505, ErodeFreq, 1);
        _e1 = MakeFbm(worldSeed + 515, ErodeFreq * 2.0, 1);
        _e2 = MakeFbm(worldSeed + 525, ErodeFreq * 4.0, 1);
        _e3 = MakeFbm(worldSeed + 535, ErodeFreq * 8.0, 1);
        _e4 = MakeFbm(worldSeed + 545, ErodeFreq * 16.0, 1);
        _river1 = MakeFbm(worldSeed + 624, RiverFreq, RiverOctaves);
        _river2 = MakeFbm(worldSeed + 634, RiverModFreq, 3);
        _coal = MakeFbm(worldSeed + 606, 0.08, 1);
        _iron = MakeFbm(worldSeed + 707, 0.09, 1);
        _cave1 = MakeFbm(worldSeed + 808, CaveFreq, CaveOctaves);
        _cave2 = MakeFbm(worldSeed + 909, CaveFreq, CaveOctaves);
        _cheese = MakeFbm(worldSeed + 1010, CheeseFreq, CheeseOctaves);
        _vein1 = MakeFbm(worldSeed + 1111, VeinFreq, VeinOctaves);
        _vein2 = MakeFbm(worldSeed + 1212, VeinFreq, VeinOctaves);
        _sourceKnots = BuildSourceQuantiles();
        _worldHeightBlocks = worldHeightBlocks;
    }

    private static FastNoiseLite MakeFbm(long seed, double frequency, int octaves)
    {
        return new FastNoiseLite
        {
            Seed = (int)seed,
            NoiseType = FastNoiseLite.NoiseTypeEnum.Simplex,
            Frequency = (float)frequency,
            // GDScript _make_fbm 未显式设 fractal_type，默认即 FBM——
            // C# 显式写出，防默认值漂移
            FractalType = FastNoiseLite.FractalTypeEnum.Fbm,
            FractalOctaves = octaves,
        };
    }

    /// 与 GDScript _build_source_quantiles 逐位一致：24x24 固定采样点
    /// 排序后取 17 个分位节点（同坐标同噪声值，排序结果相同）。
    /// 采样步长 911/929（v8 大陆波长 4096 → 窗 ~20000 格 ≈ 5 波长；
    /// 小窗会让分位节点挤成一点，全图高度塌到低端）。
    private double[] BuildSourceQuantiles()
    {
        var samples = new List<double>(24 * 24);
        for (int i = 0; i < 24; i++)
            for (int j = 0; j < 24; j++)
                samples.Add(_continental.GetNoise2D(i * 911 + 3, j * 929 + 13));
        samples.Sort();
        var knots = new double[KnotCount];
        for (int k = 0; k < KnotCount; k++)
        {
            int idx = RoundToInt((double)k / (KnotCount - 1) * (samples.Count - 1));
            knots[k] = samples[idx];
        }
        for (int k = 1; k < knots.Length; k++)
            if (knots[k] <= knots[k - 1])
                knots[k] = knots[k - 1] + 0.0001;
        return knots;
    }

    /// GD round()：half away from zero（C# Math.Round 是银行家舍入，禁用）。
    private static int RoundToInt(double x)
    {
        return (int)Math.Floor(x + 0.5);
    }

    /// 与 GDScript _shape_height 一致：噪声值线性映射到目标分位高度。
    private double ShapeHeight(double noiseValue)
    {
        if (noiseValue <= _sourceKnots[0])
            return TargetHeightFrac[0];
        for (int k = 1; k < _sourceKnots.Length; k++)
        {
            if (noiseValue <= _sourceKnots[k])
            {
                double denom = _sourceKnots[k] - _sourceKnots[k - 1];
                if (denom < 0.0001) denom = 0.0001;
                double t = (noiseValue - _sourceKnots[k - 1]) / denom;
                return TargetHeightFrac[k - 1]
                    + (TargetHeightFrac[k] - TargetHeightFrac[k - 1]) * t;
            }
        }
        return TargetHeightFrac[TargetHeightFrac.Length - 1];
    }

    /// Godot smoothstep(e0, e1, x) 的标准公式实现。
    private static double SmoothStep(double e0, double e1, double x)
    {
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    }

    private static double ClampD(double v, double lo, double hi)
    {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    /// 列剖面（与 GDScript column_profile 等价；返回三值元组而非字典）。
    /// v8 层序：分位匹配大陆 → 山系掩码×脊状山形 → Epic 侵蚀链
    /// （海岸带全幅/内陆轻调制）→ 河流窄带下切 → 气候群系。
    private (int height, bool rocky, bool sandy) ColumnProfile(int wx, int wz)
    {
        double frac = ShapeHeight(_continental.GetNoise2D(wx, wz));
        double maskRaw = _mountainMask.GetNoise2D(wx, wz);
        double gate = SmoothStep(MountainGateLo, MountainGateHi, maskRaw);
        if (gate > 0.0)
        {
            // FNL Ridged 实测 [-0.62,1]，截 [0,1] 后平方——压谷抬峰：
            // 不平方时输出均值 ~0.4，山系内部整体抬升成裸岩高原；
            // 平方后只有脊线附近满幅，山系=线状峰峦+谷地
            double ridge01 = ClampD(_ridge.GetNoise2D(wx, wz), 0.0, 1.0);
            ridge01 *= ridge01;
            frac += gate * ridge01 * MountainGain;
        }
        // Epic 式侵蚀链：大波长主体 + 逐级小系数扰动
        double e = _e0.GetNoise2D(wx, wz)
            + Math.Abs(_e1.GetNoise2D(wx, wz)) * ErodeGain1
            + Math.Abs(_e2.GetNoise2D(wx, wz)) * ErodeGain2
            + Math.Abs(_e3.GetNoise2D(wx, wz)) * ErodeGain3
            + Math.Abs(_e4.GetNoise2D(wx, wz)) * ErodeGain4;
        double coast = SmoothStep(CoastRiseLo, CoastRiseHi, frac)
            * (1.0 - SmoothStep(CoastFallLo, CoastFallHi, frac));
        frac += e * (coast * CoastErodeGain + InlandErodeGain);
        // 河流：原始 fbm 取 abs 的过零窄带，只在陆上下切
        double rn = Math.Abs(_river1.GetNoise2D(wx, wz));
        if (rn < RiverBand && frac > RiverFrac)
        {
            double rw = ClampD(_river2.GetNoise2D(wx, wz), 0.0, 1.0);
            double band = 1.0 - rn / RiverBand;
            double depth = band * (RiverBase + (1.0 - RiverBase) * rw);
            frac += (RiverFrac - frac) * Math.Min(depth, 1.0);
        }
        frac = ClampD(frac, 0.0, 1.0);
        int maxSurface = _worldHeightBlocks - 3;
        int height = RoundToInt(frac * (maxSurface - 1)) + 1;
        if (height < 1) height = 1;
        if (height > maxSurface) height = maxSurface;
        // v5：压掉齐平沙洲（height == SEA_LEVEL）
        if (height == _seaLevel)
            height = _seaLevel - 1;

        bool rocky = frac >= RockSurfaceFrac;
        double temp = _temp.GetNoise2D(wx, wz)
            - TempLapse * Math.Max(0.0, frac - 0.30);
        bool desert = !rocky && height > _sandMaxHeight
            && temp > DesertTemp && frac < DesertMaxFrac
            && _precip.GetNoise2D(wx, wz) < DesertDryness;
        bool sandy = desert || height <= _sandMaxHeight;
        return (height, rocky, sandy);
    }

    /// 与 GDScript _block_for_column 等价（rocky/sandy 已解包）。
    private int BlockForColumn(bool rocky, bool sandy,
        int wx, int wy, int wz, int height)
    {
        if (wy > height) return 0;
        if (wy == 0) return _bedrockId;
        if (wy == height)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= _sandMaxHeight) return _sandId;
            return _grassId;
        }
        if (wy >= height - DirtLayerDepth)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= _sandMaxHeight) return _sandstoneId;
            return _dirtId;
        }
        // v7 洞穴与矿脉（地表保护层内不挖——防满地天窗；基岩上留层）
        if (wy <= height - OreSurfaceMargin && wy >= 1)
        {
            if (IsCave(wx, wy, wz, height))
                return 0;
            int ore = OreVein(wx, wy, wz);
            if (ore != 0)
                return ore;
        }
        return _stoneId;
    }

    /// 隧道：双 3D 噪声等值线交叉（Minetest cavegen）；大洞厅：低频
    /// 3D 噪声超阈值（更深处）。
    private bool IsCave(int wx, int wy, int wz, int height)
    {
        double d1 = 1.0 - Math.Abs(_cave1.GetNoise3D(wx, wy, wz));
        double d2 = 1.0 - Math.Abs(_cave2.GetNoise3D(wx, wy, wz));
        if (d1 * d2 > CaveWidth)
            return true;
        if (wy <= height - CheeseMinDepth
            && _cheese.GetNoise3D(wx, wy, wz) > CheeseThreshold)
            return true;
        return false;
    }

    /// GD 侧 _hash_unit 的位同步镜像：int64 乘异或环绕 + abs 取模。
    private static double HashUnit(int x, int y, int z)
    {
        long h = (long)x * 73856093L ^ (long)y * 19349663L
            ^ (long)z * 83492791L;
        h = Math.Abs(h) % 65536;
        return h / 65536.0;
    }

    /// 矿脉细脉（Minetest mg_ore OreVein）：vein 双噪声等值线交叉
    /// + hash 抖动控制厚度；煤浅带、铁更深。
    private int OreVein(int wx, int wy, int wz)
    {
        double d1 = 1.0 - Math.Abs(_vein1.GetNoise3D(wx, wy, wz));
        double d2 = 1.0 - Math.Abs(_vein2.GetNoise3D(wx, wy, wz));
        double jitter = HashUnit(wx, wy, wz) * 2.0 - 1.0;
        double value = d1 * d2 + jitter * VeinJitter;
        if (value > IronVeinValue && wy <= _ironOreMaxY)
            return _ironOreId;
        if (value > CoalVeinValue)
            return _coalOreId;
        return 0;
    }

    /// 生成区块方块数据。返回 { ids: int[], heights: int[],
    /// sandy: byte[], rocky: byte[] }（列剖面供 GD 侧树重放复用）。
    public Variant GenerateChunk(Vector3I chunkCoord, int s)
    {
        int volume = s * s * s;
        var ids = new int[volume];
        var heights = new int[s * s];
        var sandy = new byte[s * s];
        var rocky = new byte[s * s];
        int originX = chunkCoord.X * s;
        int originY = chunkCoord.Y * s;
        int originZ = chunkCoord.Z * s;
        for (int lz = 0; lz < s; lz++)
        {
            int zOff = lz * s * s;
            for (int lx = 0; lx < s; lx++)
            {
                int wx = originX + lx;
                int wz = originZ + lz;
                var (height, isRocky, isSandy) = ColumnProfile(wx, wz);
                int colIdx = lz * s + lx;
                heights[colIdx] = height;
                sandy[colIdx] = isSandy ? (byte)1 : (byte)0;
                rocky[colIdx] = isRocky ? (byte)1 : (byte)0;
                int col = zOff + lx;
                for (int ly = 0; ly < s; ly++)
                {
                    int wy = originY + ly;
                    int blockId;
                    if (wy > height && wy <= _seaLevel)
                        blockId = _waterId;
                    else
                        blockId = BlockForColumn(isRocky, isSandy, wx, wy, wz, height);
                    ids[col + ly * s] = blockId;
                }
            }
        }
        var result = new Godot.Collections.Dictionary
        {
            ["ids"] = Variant.CreateFrom(ids),
            ["heights"] = Variant.CreateFrom(heights),
            ["sandy"] = Variant.CreateFrom(sandy),
            ["rocky"] = Variant.CreateFrom(rocky),
        };
        return Variant.CreateFrom(result);
    }

    /// 列足迹地表高度区间（v9 垂直流式加载带的依据）：(s+2)² 外扩
    /// 一格——悬崖恰在列边界时，崖壁属于高列方块却面向低列，外圈
    /// 把低列高度纳入高列区间，保证崖壁所在层被加载（否则崖壁中段
    /// 不加载=悬崖开洞）。返回 (minH, maxH)。
    public Vector2I ColumnSurfaceRange(int chunkX, int chunkZ, int s)
    {
        int minH = int.MaxValue;
        int maxH = int.MinValue;
        int ox = chunkX * s - 1;
        int oz = chunkZ * s - 1;
        for (int z = 0; z < s + 2; z++)
        {
            for (int x = 0; x < s + 2; x++)
            {
                var (h, _, _) = ColumnProfile(ox + x, oz + z);
                if (h < minH) minH = h;
                if (h > maxH) maxH = h;
            }
        }
        return new Vector2I(minH, maxH);
    }

    // ---- 远景山壳 v3（DH 源码机制移植，distant-horizons-core）----
    // 用户定调：LOD 必须保持体素语言——每级用更粗的"方块"渲染，
    // 与 chunk 体素同一视觉语言（平滑高度场网格像"平面贴图"，
    // 实机否决）。v2 四轮实机伪影（拉伸条纹/级间断层）对照 DH
    // ColumnBox.java 定根后全部推翻：
    // ① 环带不重叠——v2 相邻级世界坐标重叠 128 格，粗级格顶
    //   （2×2 采样 max）系统性偏高从细级地形里穿出=级间断层；
    //   DH 每级只管自己的环带（detail 差恒 1），边界由侧壁衔接。
    // ② 高度=格中心列真实值，不用 2×2 max——max 把山脊展宽成
    //   等高平台连片（远处"拉长"主因）；DH datapoint 高度是格内
    //   真实数据聚合，无 max 偏置。
    // ③ 高程不量化（DH yMin/yMax 精确到块）——v2 的 vs=S/8 把
    //   相近高度拍平成等高平台再叠加 run 合并=超长横条。格距粗
    //   （水平精度降）但每格高度精确 → 远处丘陵细节保留、无平台。
    // ④ 侧壁逐格生成，绝不横向合并——DH makeAdjVerticalQuad 每
    //   列每段独立 quad；v2 等高 run 合并（哪怕限 3 格）×S=16
    //   仍是 48 格长墙=拉伸条纹残余。
    // ⑤ 级间衔接查真实地形：跨界邻格顶=CellTop 纯函数（任何级
    //   任何格随时可算），朝细级侧按邻级格宽分段取 min（壁底贴
    //   真实地形=无缝，略过绘同 DH onBorder overdraw 思想）；
    //   最外缘/视距圈侧才用固定裙深（雾吞区）。
    // (格距 S, 内缘世界格, 外缘世界格)——半径单位=世界格。级间
    // 边界 768/2048 是各级格距公倍数，全局对齐网格无游移。
    // 内缘 160：壳中心 64 格步进游移下最坏内缘=160+64=224 <
    // chunk 视距 256——恒重叠 32 格以上。曾内缘 240（+64 游移
    // 最坏 304>256）：视距边缘 8-16 格真空带（"真实地形边缘悬空
    // 土柱、柱间透天空"实机——v2 起结构性缺陷，壳从未与 chunk
    // 圈保证衔接）；重叠区共面由壳节点整体下沉 2 格防 z-fighting
    private static readonly (int s, int inner, int outer)[] ShellLevels =
    {
        (4, 160, 768),
        (8, 768, 2048),
        (16, 2048, 4096),
    };

    // 某世界半径处壳的格距（跨界邻格查询用；环外返回 0）
    private static int ShellStepAt(int worldR)
    {
        foreach (var (s, inner, outer) in ShellLevels)
            if (worldR >= inner && worldR < outer)
                return s;
        return 0;
    }

    public ArrayMesh GenerateShellMesh(int centerX, int centerZ)
    {
        var mesh = new ArrayMesh();
        // 水面（第十轮定案保留）：无独立水面几何，水格出方块顶面
        //（sea+0.3，恒在真水波谷下），与陆格同一生成路径——远处
        // 水面=大方块，与真实体素水同一视觉语言
        foreach (var (S, ringInW, ringOutW) in ShellLevels)
        {
            int RingInner = ringInW;
            int RingOuter = ringOutW;
            int W = (RingOuter / S) * 2;
            // 高程不量化（DH yMin/yMax 精确到块）：格距粗=水平精度
            // 降，但每格高度精确到 1 格——曾 vs=S/8 量化把相近高度
            // 拍平成等高平台（远处丘陵失细节、拉长感来源之一）。
            // q=群系/水陆统计的 2×2 采样内缩
            int q = Math.Max(1, S / 4);
            var tops = new int[W * W];
            var biome = new byte[W * W];   // 0 水 1 草 2 岩 3 沙
            var tint = new float[W * W];
            // 群系计数（顶面/壁的混合色源）：逐格颜色差异是 DH 打
            // 破等高连片的关键（其顶面色=格内主导方块色，草/石/土
            // /沙 混合斑驳）——我们同 biome 等高壁共面同色，远看
            // 连成 100+ 格横条（放大裁剪实锤）。混合色让每格在等
            // 高平台上仍有色斑=方砖感
            var grassN = new byte[W * W];
            var rockN = new byte[W * W];
            var sandN = new byte[W * W];
            // 格中心距壳心距离（水色过渡用——真水→壳水观感衔接）
            var rdist = new int[W * W];
            var inRing = new bool[W * W];
            for (int cz = 0; cz < W; cz++)
            for (int cx = 0; cx < W; cx++)
            {
                // 圆环判定（欧氏半径，世界格、格中心）：方环的角区比
                // 边区远 √2——雾化梯度沿对角突变，透视下呈放射状亮
                // 楔穿水穿山（海边低机位实机复现）；圆环雾梯度平滑
                //（DH 同款）。格仍方形对齐（判定圆、格方）
                int bx = centerX + (cx - W / 2) * S;
                int bz = centerZ + (cz - W / 2) * S;
                int ddx = bx + S / 2 - centerX;
                int ddz = bz + S / 2 - centerZ;
                int r2 = ddx * ddx + ddz * ddz;
                if (r2 < RingInner * RingInner
                    || r2 >= RingOuter * RingOuter)
                    continue;
                int ci = cz * W + cx;
                inRing[ci] = true;
                rdist[ci] = (int)Math.Sqrt((double)r2);
                // 高度=格中心列真实值（DH datapoint 同思想：格内真实
                // 数据，无 max 偏置——max 会把山脊展宽成等高平台，
                // 远处"拉长"主因）。2×2 采样只做群系/水陆统计
                var (hCenter, _, _) = ColumnProfile(
                    bx + S / 2, bz + S / 2);
                int grass = 0, rock = 0, sand = 0, waterN = 0;
                int hMin = int.MaxValue;
                for (int sz = 0; sz < 2; sz++)
                for (int sx = 0; sx < 2; sx++)
                {
                    var (h, isRocky, isSandy) = ColumnProfile(
                        bx + (sx == 0 ? q : S - 1 - q),
                        bz + (sz == 0 ? q : S - 1 - q));
                    if (h < hMin) hMin = h;
                    if (h <= _seaLevel) waterN++;
                    else if (isRocky) rock++;
                    else if (isSandy) sand++;
                    else grass++;
                }
                // 每格独立明度抖动（格坐标 hash，非连续噪声）：连
                // 续噪声相邻格值相近，等高带上颜色仍连续——20-80
                // 格条带残余（放大实锤）。独立 hash 让相邻等高格明
                // 度随机跳变，长条带碎成 1 格宽方砖（DH per-block
                // dithering 同效；混合色+tint 加幅后放大裁剪 2/10
                // → 目标 7+）
                uint hsh = (uint)(bx * 374761393 + bz * 668265263);
                hsh = (hsh ^ (hsh >> 13)) * 1274126177;
                tint[ci] = ((hsh >> 16) & 0xFF) / 255.0f * 2.0f - 1.0f;
                grassN[ci] = (byte)grass;
                rockN[ci] = (byte)rock;
                sandN[ci] = (byte)sand;
                if (waterN == 4)
                {
                    biome[ci] = 0;
                    tops[ci] = _seaLevel - 1;
                }
                else if (waterN > 0)
                {
                    // 半水格（2×2 采样部分水）：整格藏水下 2 格，滩面
                    // 由周围全陆格表达（曾按陆格出顶：浅滩区大量格顶
                    // 恰好=海平面，连成贴水方块层——"水的方块拼贴"
                    // 实机八轮定位）
                    biome[ci] = rock >= sand && rock >= grass ? (byte)2
                        : sand >= grass ? (byte)3 : (byte)1;
                    tops[ci] = _seaLevel - 2;
                }
                else
                {
                    biome[ci] = rock >= sand && rock >= grass ? (byte)2
                        : sand >= grass ? (byte)3 : (byte)1;
                    // 全陆格至少露出水面 1 格：既避开与壳水格顶
                    //（sea+0.3）贴面，又不会把浅滩整片拔高。
                    // 重叠带（r≤288：chunk 恒覆盖 256+壳中心游移
                    // 32）：顶取 5 点采样 min（中心+2×2 角）——恒
                    // 不高于格内真实列，绝不从真实地形里穿出（实机
                    // "真实边缘与 LOD 重合"=中心列恰在局部高点时壳
                    // 叠在真实地形上）；压低不露洞：chunk 切墙是
                    // 全高面，墙脚永远落地。288 外恢复中心列（正常
                    // LOD 采样），过渡由逐格壁表达
                    int top = rdist[ci] <= 288
                        ? Math.Min(hCenter, hMin)
                        : hCenter;
                    tops[ci] = Math.Max(top, _seaLevel + 1);
                }
            }

            // ---- 海岸带缓坡化（离水格逐级压低）----
            // 陡岸上 2×2 采样取的是最大值，临水陆格的顶就是坡顶高度；
            // 而相邻水格整格不出面（biome=0），于是每块临水陆格都朝水
            // 生成一整片从坡顶直落海面的高墙，墙间露出壳水面圆盘——
            // 远景看就是一排悬在水上的灰板幕帘（用户实机截图）。
            // 做法：以"水下格"（全水格 sea-1 与半水格 sea-2）为源做
            // BFS 距离场（扩散上限 4 格），把陆格顶钳到
            // sea+1+(d-1)*step，海岸线变成一级一级下水的缓坡，单面
            // 墙高被压到 step 量级。半径上限：曾无限制扩散整个环带
            // ——sea+5~sea+45 的大片丘陵全落入压制范围（cap=sea+1+
            // 2(d-1)），被拍成每 2 格一级的规则缓坡="断层处一整个
            // 斜面没有任何地形结构"（实机截图实锤，用户定位"LOD
            // 地形生成部分地方有问题"）；压临水 1-4 格已足够防幕帘
            const int CoastRadius = 4;
            int coastStep = Math.Max(2, S / 8);
            var dist = new int[W * W];
            for (int i = 0; i < dist.Length; i++)
                dist[i] = -1;
            var frontier = new Queue<int>();
            for (int i = 0; i < W * W; i++)
            {
                if (!inRing[i] || tops[i] > _seaLevel)
                    continue;
                dist[i] = 0;
                frontier.Enqueue(i);
            }
            while (frontier.Count > 0)
            {
                int i = frontier.Dequeue();
                if (dist[i] >= CoastRadius)
                    continue;
                int nd = dist[i] + 1;
                int ix = i % W;
                int iz = i / W;
                for (int k = 0; k < 4; k++)
                {
                    int nx = ix + (k == 0 ? 1 : k == 1 ? -1 : 0);
                    int nz = iz + (k == 2 ? 1 : k == 3 ? -1 : 0);
                    if (nx < 0 || nx >= W || nz < 0 || nz >= W)
                        continue;
                    int ni = nz * W + nx;
                    if (!inRing[ni] || dist[ni] >= 0)
                        continue;
                    dist[ni] = nd;
                    frontier.Enqueue(ni);
                }
            }
            for (int i = 0; i < W * W; i++)
            {
                if (!inRing[i] || tops[i] <= _seaLevel || dist[i] < 1)
                    continue;
                int cap = _seaLevel + 1 + (dist[i] - 1) * coastStep;
                if (tops[i] > cap)
                    tops[i] = cap;
            }

            // ---- 边界圈高度钳制（DH 数据金字塔的单调性：父级 ≥
            // 子级每格）---- 独立中心列采样让级间高度不单调：粗级
            // 首圈可凭空高于细级末圈（768 边界"灰白条带矮墙"实机）
            // 或壳内缘格低于真实地形列（240 边界真实地形边缘悬空露
            // 断面——"悬空土柱"实机）。钳制：本格在某方向出环且该
            // 方向朝内（邻中心更近壳心）时，格顶抬到内侧细一级网格
            // 邻格顶的 max——边界处高度由内侧承接（壁由内侧格出到
            // 本格顶），无洞无错位；"本格高于内侧"由本格跨界壁兜
            // 底（画到内侧真实高度-2 过绘）。内缘朝真实区逐列钳
            //（step=1）；768/2048 朝内分别按 4/8 网格分段
            int[] kdx = { 1, -1, 0, 0 };
            int[] kdz = { 0, 0, 1, -1 };
            for (int cz2 = 0; cz2 < W; cz2++)
            for (int cx2 = 0; cx2 < W; cx2++)
            {
                int ci2 = cz2 * W + cx2;
                // 重叠带（r≤288）格由 chunk 完整覆盖+min 采样保证
                // 不穿出——max 钳制只服务裸露区级间衔接（内缘 160
                // 深处曾=交界，现交界在 chunk 边 256，深处的 max
                // 抬升反而把壳顶抬回真实地形之上=穿出复发）
                if (!inRing[ci2] || biome[ci2] == 0
                    || rdist[ci2] <= 288)
                    continue;
                int bx2 = centerX + (cx2 - W / 2) * S;
                int bz2 = centerZ + (cz2 - W / 2) * S;
                float ccx = bx2 + S * 0.5f - centerX;
                float ccz = bz2 + S * 0.5f - centerZ;
                float cc2 = ccx * ccx + ccz * ccz;
                for (int k = 0; k < 4; k++)
                {
                    int nx2 = cx2 + kdx[k], nz2 = cz2 + kdz[k];
                    if (nx2 >= 0 && nx2 < W && nz2 >= 0 && nz2 < W
                        && inRing[nz2 * W + nx2])
                        continue;  // 环内邻居无需钳
                    float ndx = ccx + kdx[k] * S;
                    float ndz = ccz + kdz[k] * S;
                    if (ndx * ndx + ndz * ndz >= cc2)
                        continue;  // 只钳朝内方向（外缘由跨界壁兜底）
                    int nR = (int)Math.Sqrt(ndx * ndx + ndz * ndz);
                    int sN = ShellStepAt(nR);
                    if (sN >= S)
                        continue;  // 邻侧不更细（异常）不钳
                    int step = sN > 0 ? sN : 1;
                    int nSeg2 = S / step;
                    for (int seg = 0; seg < nSeg2; seg++)
                    {
                        float mid = seg * step + step * 0.5f;
                        int px = kdx[k] != 0
                            ? bx2 + (kdx[k] > 0 ? S : 0)
                                + kdx[k] * (step / 2)
                            : bx2 + (int)mid;
                        int pz = kdz[k] != 0
                            ? bz2 + (kdz[k] > 0 ? S : 0)
                                + kdz[k] * (step / 2)
                            : bz2 + (int)mid;
                        int nbTop = CellTopAt(px, pz);
                        if (nbTop > tops[ci2])
                            tops[ci2] = nbTop;
                    }
                }
            }

            var verts = new List<Vector3>();
            var norms = new List<Vector3>();
            var cols = new List<Color>();
            var idxs = new List<int>();

            void PushQuad(Vector3 a, Vector3 b, Vector3 c, Vector3 d,
                Vector3 n, Color col)
            {
                int v0 = verts.Count;
                verts.Add(a); verts.Add(b); verts.Add(c); verts.Add(d);
                norms.Add(n); norms.Add(n); norms.Add(n); norms.Add(n);
                cols.Add(col); cols.Add(col); cols.Add(col); cols.Add(col);
                idxs.Add(v0); idxs.Add(v0 + 2); idxs.Add(v0 + 1);
                idxs.Add(v0 + 1); idxs.Add(v0 + 2); idxs.Add(v0 + 3);
            }

            // 格色：水格=纯水色不吃 tint（±色差透过半透明真水=水下
            // "神秘纹路"移动视差闪，实机定案）；陆格=群系计数加权混
            // 合色 + 每格 hash 抖动 ±16%（曾单 biome 色+连续噪声
            // ±8%：同 biome 等高格颜色几乎一致，等高平台/等高壁连
            // 片成 100+ 格横条——放大裁剪实锤；DH 靠格内主导方块
            // 色差打破连片，混合色+独立抖动同效）。三基色=真实纹理
            // 平均色 PIL 抽样（grass_top/stone/sand.png）——240 边
            // 界"深绿突变浅黄绿"（旧沙色 0.72/0.66/0.49 偏亮黄是
            // 主犯）。曾把水格漏出本函数（计数全 0 落保护分支返回
            // 纯黑）——"水没了"实机一轮
            Color MixCol(int ci, float t)
            {
                if (biome[ci] == 0)
                {
                    // 水色距离过渡（实机水侧 256 交界"亮蓝有浪→灰
                    // 蓝无浪平直横线"）：近端延续真水观感（深蓝
                    // 0.19/0.27/0.42，截图像素抽样），640 外渐到雾
                    // 化灰蓝——浪纹细节差靠颜色+雾压住（静态 mesh
                    // 无从生浪）；重叠带 [160,256] 透过真水看到的
                    // 也是这色=水色深度自然
                    float f = Math.Min(1.0f, Math.Max(0.0f,
                        (rdist[ci] - 256.0f) / 384.0f));
                    f = f * f * (3.0f - 2.0f * f);
                    return new Color(
                        0.19f + 0.09f * f,
                        0.27f + 0.10f * f,
                        0.42f + 0.05f * f);
                }
                float k = 1.0f + 0.16f * t;
                float tot = grassN[ci] + rockN[ci] + sandN[ci];
                if (tot <= 0)
                    tot = 1;
                return new Color(
                    (0.26f * grassN[ci] + 0.53f * rockN[ci]
                        + 0.50f * sandN[ci]) / tot * k,
                    (0.35f * grassN[ci] + 0.52f * rockN[ci]
                        + 0.47f * sandN[ci]) / tot * k,
                    (0.16f * grassN[ci] + 0.49f * rockN[ci]
                        + 0.37f * sandN[ci]) / tot * k);
            }

            // 格顶面（陆格=量化高度；水格=sea-0.125 方块风水面，
            // 与 chunk 水面同高公式——重叠区 240-256 由 chunk 水面
            // 覆盖，非重叠区水格即"大方块水面"）
            for (int cz = 0; cz < W; cz++)
            for (int cx = 0; cx < W; cx++)
            {
                int ci = cz * W + cx;
                if (!inRing[ci])
                    continue;
                float x0 = centerX + (cx - W / 2) * (float)S;
                float z0 = centerZ + (cz - W / 2) * (float)S;
                // 水格顶面沉到 sea+0.3：真水面（已回退带言波+涟漪位移
                // clamp[-0.16,+0.56]）最低点 sea+0.715——壳格恒在波谷
                // 之下 0.4 格，任何波态不穿插（贴太近+位移水面=穿插
                // 闪烁，水面 LOD 修复期的根因总结）；透过半透明水看到
                // 的是深 0.5 格的均匀纯色底
                float y = biome[ci] == 0
                    ? _seaLevel + 0.3f
                    : tops[ci];
                PushQuad(new Vector3(x0, y, z0),
                    new Vector3(x0 + S, y, z0),
                    new Vector3(x0, y, z0 + S),
                    new Vector3(x0 + S, y, z0 + S),
                    Vector3.Up, MixCol(ci, tint[ci]));
            }

            // 任意世界点处的跨界格顶估计（与主循环 tops 同语义、取
            // 更保守的低值）：中心列真实高度；水面带（全水/半水/滩，
            // 中心列 ≤sea+1）一律藏底值 sea-2——跨界壁底取低只会过
            // 绘不会悬空露缝
            int CellTopAt(int px, int pz)
            {
                var (h, _, _) = ColumnProfile(px, pz);
                return h <= _seaLevel + 1 ? _seaLevel - 2 : h;
            }

            // 壁发射：p0=底边起点，t=切向全长（绕序 flip：几何法线
            // cross(up,t) 须与 n 同向——cull_disabled 下 Godot 把背面
            // 片元 NORMAL 取反，反向墙会被当朝阳面照亮，海岸失去
            // 体素明暗）
            void PushWall(Vector3 p0, Vector3 t, float yt, float yb,
                Vector3 n, bool flip, Color col)
            {
                var up = new Vector3(0, yt - yb, 0);
                Vector3 va = p0, vb = p0 + t,
                    vc = p0 + up, vd = p0 + t + up;
                if (flip)
                {
                    var swap = vb;
                    vb = vc;
                    vc = swap;
                }
                PushQuad(va, vb, vc, vd, n, col);
            }

            // 侧壁：逐格生成，绝不横向合并（DH makeAdjVerticalQuad
            // 每列独立 quad；等高 run 合并哪怕限 3 格，×S=16 仍是
            // 48 格长墙=拉伸条纹残余）。环内邻：低侧不出壁（同网格
            // 数据一致，无缝）；跨界邻（级间边界/最外缘/视距圈）：
            // 无条件画壁且壁底压到跨界格顶之下 2 格（DH onBorder
            // 永画 + overdraw 防洞同思想）——两侧高度估计各有误差，
            // 双侧背靠背过绘保证任何偏差下无缝。朝细级侧按邻级格
            // 宽分段查真实地形，段底=段内邻格顶-2
            int[] dxs = { 1, -1, 0, 0 };
            int[] dzs = { 0, 0, 1, -1 };
            for (int dir = 0; dir < 4; dir++)
            {
                int dx = dxs[dir], dz = dzs[dir];
                var n = new Vector3(dx, 0, dz);
                bool flip = dx < 0 || dz > 0;
                for (int cz = 0; cz < W; cz++)
                for (int cx = 0; cx < W; cx++)
                {
                    int ci = cz * W + cx;
                    if (!inRing[ci] || biome[ci] == 0)
                        continue;
                    int yt = tops[ci];
                    float x0 = centerX + (cx - W / 2) * (float)S;
                    float z0 = centerZ + (cz - W / 2) * (float)S;
                    int nx = cx + dx, nz = cz + dz;
                    bool nbOk = nx >= 0 && nx < W && nz >= 0 && nz < W
                        && inRing[nz * W + nx];
                    var wallCol = MixCol(ci, tint[ci]) * 0.9f;
                    if (nbOk)
                    {
                        int ni = nz * W + nx;
                        int nbTop = biome[ni] == 0
                            ? _seaLevel - 1 : tops[ni];
                        if (yt <= nbTop)
                            continue;
                        Vector3 p0 = new Vector3(
                            dx != 0 ? (dx > 0 ? x0 + S : x0) : x0,
                            nbTop,
                            dz != 0 ? (dz > 0 ? z0 + S : z0) : z0);
                        Vector3 t = dx != 0
                            ? new Vector3(0, 0, S)
                            : new Vector3(S, 0, 0);
                        PushWall(p0, t, yt, nbTop, n, flip, wallCol);
                        continue;
                    }
                    // ---- 跨界壁（级间边界/最外缘/视距圈）----
                    // 探针：本格中心沿方向推进一格（邻格中心近似，
                    // 判它属于哪级；曾用格角点 z0——斜向边界处判级
                    // 偏差）
                    int edgeX = dx != 0
                        ? (int)(dx > 0 ? x0 + S : x0) : (int)x0;
                    int edgeZ = dz != 0
                        ? (int)(dz > 0 ? z0 + S : z0) : (int)z0;
                    int probeX = (int)x0 + S / 2 + dx * S;
                    int probeZ = (int)z0 + S / 2 + dz * S;
                    int ddx = probeX - centerX;
                    int ddz = probeZ - centerZ;
                    int probeR = (int)Math.Sqrt(
                        (double)(ddx * ddx + ddz * ddz));
                    int sOut = ShellStepAt(probeR);
                    int nSeg = 1, segW = S;
                    if (sOut > 0 && sOut < S)
                    {
                        nSeg = S / sOut;
                        segW = sOut;
                    }
                    for (int k = 0; k < nSeg; k++)
                    {
                        int yb;
                        if (sOut > 0)
                        {
                            // 段中点外侧半格 = 邻格中心
                            float mid = k * segW + segW * 0.5f;
                            int px = dx != 0
                                ? edgeX + dx * (sOut / 2)
                                : (int)(x0 + mid);
                            int pz = dz != 0
                                ? edgeZ + dz * (sOut / 2)
                                : (int)(z0 + mid);
                            yb = CellTopAt(px, pz) - 2;
                        }
                        else
                        {
                            // 无邻级：朝内到真实区（240 内缘）贴真实
                            // 地形-2（与级间同规则，真实地形边缘不出
                            // 悬空断面）；仅最外缘（4096 外）用固定
                            // 裙深（雾吞区兜底）
                            yb = probeR < RingInner
                                ? CellTopAt(probeX, probeZ) - 2
                                : Math.Max(tops[ci] - S, _seaLevel - 1);
                        }
                        if (yt <= yb)
                            continue;
                        float wOff = k * (float)segW;
                        Vector3 p0 = new Vector3(
                            dx != 0 ? (dx > 0 ? x0 + S : x0)
                                : x0 + wOff,
                            yb,
                            dz != 0 ? (dz > 0 ? z0 + S : z0)
                                : z0 + wOff);
                        Vector3 t = dx != 0
                            ? new Vector3(0, 0, segW)
                            : new Vector3(segW, 0, 0);
                        PushWall(p0, t, yt, yb, n, flip, wallCol);
                    }
                }
            }

            var arrays = new Godot.Collections.Array();
            arrays.Resize((int)Mesh.ArrayType.Max);
            arrays[(int)Mesh.ArrayType.Vertex] =
                Variant.CreateFrom(verts.ToArray());
            arrays[(int)Mesh.ArrayType.Normal] =
                Variant.CreateFrom(norms.ToArray());
            arrays[(int)Mesh.ArrayType.Color] =
                Variant.CreateFrom(cols.ToArray());
            arrays[(int)Mesh.ArrayType.Index] =
                Variant.CreateFrom(idxs.ToArray());
            mesh.AddSurfaceFromArrays(
                Mesh.PrimitiveType.Triangles, arrays);
        }
        return mesh;
    }
}
