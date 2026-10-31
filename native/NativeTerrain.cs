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
    private const int SandMaxHeight = 8;
    private const int IronOreMaxY = 20;
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
    private const int SeaLevel = 7;
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
        if (height == SeaLevel)
            height = SeaLevel - 1;

        bool rocky = frac >= RockSurfaceFrac;
        double temp = _temp.GetNoise2D(wx, wz)
            - TempLapse * Math.Max(0.0, frac - 0.30);
        bool desert = !rocky && height > SandMaxHeight
            && temp > DesertTemp && frac < DesertMaxFrac
            && _precip.GetNoise2D(wx, wz) < DesertDryness;
        bool sandy = desert || height <= SandMaxHeight;
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
            if (sandy || height <= SandMaxHeight) return _sandId;
            return _grassId;
        }
        if (wy >= height - DirtLayerDepth)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= SandMaxHeight) return _sandstoneId;
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
        if (value > IronVeinValue && wy <= IronOreMaxY)
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
                    if (wy > height && wy <= SeaLevel)
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
}
